-- Alfred-Margaret: Fast Aho-Corasick string searching
-- Copyright 2022 Channable
--
-- Licensed under the 3-clause BSD license, see the LICENSE file in the
-- repository root.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | An efficient implementation of the Aho-Corasick string matching algorithm.
-- See http://web.stanford.edu/class/archive/cs/cs166/cs166.1166/lectures/02/Small02.pdf
-- for a good explanation of the algorithm.
--
-- The memory layout of the automaton, and the function that steps it, were
-- optimized to the point where string matching compiles roughly to a loop over
-- the code units in the input text, that keeps track of the current state.
-- Lookup of the next state is either just an array index (for the root state),
-- or a linear scan through a small array (for non-root states). The pointer
-- chases that are common for traversing Haskell data structures have been
-- eliminated.
--
-- The construction of the automaton has not been optimized that much, because
-- construction time is usually negligible in comparison to matching time.
-- Therefore construction is a two-step process, where first we build the
-- automaton as int maps, which are convenient for incremental construction.
-- Afterwards we pack the automaton into unboxed vectors.
--
-- This module is a rewrite of the previous version which used an older version of
-- the 'text' package which in turn used UTF-16 internally.
module Data.Text.Utf8.AhoCorasick.Automaton where

import Data.Bits (Bits (shiftL, shiftR, (.&.), (.|.)))
import Data.Char (chr)
import Data.Foldable (foldl')
import Data.IntMap.Strict (IntMap)
import Data.Word (Word32, Word64)

import qualified Data.Char as Char
import qualified Data.IntMap.Strict as IntMap
import qualified Data.List as List
import qualified Data.Vector as Vector
import qualified Data.Vector.Unboxed as UVector

import Data.Text.Utf8 (CodeUnit, CodeUnitIndex (CodeUnitIndex), Text (..), indexTextArray)

import qualified Data.Text.Utf8 as Utf8

data CaseSensitivity = CaseSensitive | IgnoreCase
  deriving Eq

-- TYPES
-- | A numbered state in the Aho-Corasick automaton.
type State = Int

-- | A transition is a pair of (code unit, next state). The code unit is 8 bits,
-- and the state index is 32 bits. We pack these together as a manually unlifted
-- tuple, because an unboxed Vector of tuples is a tuple of vectors, but we want
-- the elements of the tuple to be adjacent in memory. (The Word64 still needs
-- to be unpacked in the places where it is used.) The code unit is stored in
-- the least significant 32 bits, with the special value 2^8 indicating a
-- wildcard; the "failure" transition. Bit 9 through 31 (starting from zero,
-- both bounds inclusive) are always 0.
--
--
-- >  Bit 63 (most significant)                 Bit 0 (least significant)
-- >  |                                                                 |
-- >  v                                                                 v
-- > |<--       goto state         -->|<--       zeros     -->| |<-input>|
-- > |SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS|00000000000000000000000|W|IIIIIIII|
-- >                                                           |
-- >                                                 Wildcard bit (bit 8)
--
-- If you change this representation, make sure to update 'transitionCodeUnit',
-- 'wildcard', 'transitionState', 'transitionIsWildcard', 'newTransition' and
-- 'newWildcardTransition' as well. Those functions form the interface used to
-- construct and read transitions.
type Transition = Word64

data Match v = Match
  { matchPos   :: {-# UNPACK #-} !CodeUnitIndex
  -- ^ The code unit index past the last code unit of the match. Note that this
  -- is not a code *point* (Haskell `Char`) index; a code point might be encoded
  -- as two code units.
  , matchValue :: v
  -- ^ The payload associated with the matched needle.
  }

-- | An Aho-Corasick automaton.
data AcMachine v = AcMachine
  { machineValues               :: !(Vector.Vector [v])
  -- ^ For every state, the values associated with its needles. If the state is
  -- not a match state, the list is empty.
  , machineTransitions          :: !(UVector.Vector Transition)
  -- ^ A packed vector of transitions. For every state, there is a slice of this
  -- vector that starts at the offset given by `machineOffsets`, and ends at the
  -- first wildcard transition.
  , machineOffsets              :: !(UVector.Vector Int)
  -- ^ For every state, the index into `machineTransitions` where the transition
  -- list for that state starts.
  , machineRootAsciiTransitions :: !(UVector.Vector Transition)
  -- ^ A lookup table for transitions from the root state, an optimization to
  -- avoid having to walk all transitions, at the cost of using a bit of
  -- additional memory.
  }

-- AUTOMATON CONSTRUCTION

-- | The wildcard value is 2^8, one more than the maximal 8-bit code unit (255/0xff).
wildcard :: Integral a => a
wildcard = 0x100

-- | Extract the code unit from a transition. The special wildcard transition
-- will return 0.
transitionCodeUnit :: Transition -> CodeUnit
transitionCodeUnit t = fromIntegral (t .&. 0xff)

-- | Extract the goto state from a transition.
transitionState :: Transition -> State
transitionState t = fromIntegral (t `shiftR` 32)

-- | Test if the transition is not for a specific code unit, but the wildcard
-- transition to take if nothing else matches.
transitionIsWildcard :: Transition -> Bool
transitionIsWildcard t = (t .&. wildcard) == wildcard

newTransition :: CodeUnit -> State -> Transition
newTransition input state =
  let
    input64 = fromIntegral input :: Word64
    state64 = fromIntegral state :: Word64
  in
    (state64 `shiftL` 32) .|. input64

newWildcardTransition :: State -> Transition
newWildcardTransition state =
  let
    state64 = fromIntegral state :: Word64
  in
    (state64 `shiftL` 32) .|. wildcard

-- | Pack transitions for each state into one contiguous array. In order to find
-- the transitions for a specific state, we also produce a vector of start
-- indices. All transition lists are terminated by a wildcard transition, so
-- there is no need to record the length.
packTransitions :: [[Transition]] -> (UVector.Vector Transition, UVector.Vector Int)
packTransitions transitions =
  let
    packed = UVector.fromList $ concat transitions
    offsets = UVector.fromList $ scanl (+) 0 $ fmap List.length transitions
  in
    (packed, offsets)

-- | Construct an Aho-Corasick automaton for the given needles.
-- The automaton uses UTF-8 code units (bytes) to match the input.
-- This means that running it is a bit tricky if you want to ignore case,
-- since changing a code point's case may increase or decrease its number of code units.
build :: [([CodeUnit], v)] -> AcMachine v
build needlesWithValues =
  let
    -- Construct the Aho-Corasick automaton using IntMaps, which are a suitable
    -- representation when building the automaton. We use int maps rather than
    -- hash maps to ensure that the iteration order is the same as that of a
    -- vector.
    (numStates, transitionMap, initialValueMap) = buildTransitionMap needlesWithValues
    fallbackMap = buildFallbackMap transitionMap
    valueMap = buildValueMap transitionMap fallbackMap initialValueMap

    -- Convert the map of transitions, and the map of fallback states, into a
    -- list of transition lists, where every transition list is terminated by
    -- a wildcard transition to the fallback state.
    prependTransition ts input state = newTransition (fromIntegral input) state : ts
    makeTransitions fallback ts = IntMap.foldlWithKey' prependTransition [newWildcardTransition fallback] ts
    transitionsList = zipWith makeTransitions (IntMap.elems fallbackMap) (IntMap.elems transitionMap)

    -- Pack the transition lists into one contiguous array, and build the lookup
    -- table for the transitions from the root state.
    (transitions, offsets) = packTransitions transitionsList
    rootTransitions = buildAsciiTransitionLookupTable $ transitionMap IntMap.! 0
    values = Vector.generate numStates (valueMap IntMap.!)
  in
    AcMachine values transitions offsets rootTransitions

-- | Build the automaton, and format it as Graphviz Dot, for visual debugging.
debugBuildDot :: [[CodeUnit]] -> String
debugBuildDot needles =
  let
    (_numStates, transitionMap, initialValueMap) =
      buildTransitionMap $ zip needles ([0..] :: [Int])
    fallbackMap = buildFallbackMap transitionMap
    valueMap = buildValueMap transitionMap fallbackMap initialValueMap

    dotEdge extra state nextState =
      "  " ++ show state ++ " -> " ++ show nextState ++ " [" ++ extra ++ "];"

    dotFallbackEdge :: [String] -> State -> State -> [String]
    dotFallbackEdge edges state nextState =
      dotEdge "style = dashed" state nextState : edges

    dotTransitionEdge :: State -> [String] -> Int -> State -> [String]
    dotTransitionEdge state edges input nextState =
      dotEdge ("label = \"" ++ showInput input ++ "\"") state nextState : edges

    showInput input
      | input < 0x80 = [chr input]
      | otherwise     = "0x" ++ asHexByte input

    asHexByte input =
      [hexChars List.!! div input 16, hexChars List.!! mod input 16]
      where hexChars = ['0'..'9'] ++ ['a'..'f']

    prependTransitionEdges edges state =
      IntMap.foldlWithKey' (dotTransitionEdge state) edges (transitionMap IntMap.! state)

    dotMatchState :: [String] -> State -> [Int] -> [String]
    dotMatchState edges _ [] = edges
    dotMatchState edges state _ = ("  " ++ show state ++ " [shape = doublecircle];") : edges

    dot0 = foldBreadthFirst prependTransitionEdges [] transitionMap
    dot1 = IntMap.foldlWithKey' dotFallbackEdge dot0 fallbackMap
    dot2 = IntMap.foldlWithKey' dotMatchState dot1 valueMap
  in
    -- Set rankdir = "LR" to prefer a left-to-right graph, rather than top to
    -- bottom. I have dual widescreen monitors and I don't use them in portrait
    -- mode. Reverse the instructions because order affects node lay-out, and by
    -- prepending we built up a reversed list.
    unlines $ ["digraph {", "  rankdir = \"LR\";"] ++ reverse dot2 ++ ["}"]

-- Different int maps that are used during constuction of the automaton. The
-- transition map represents the trie of states, the fallback map contains the
-- fallback (or "failure" or "suffix") edge for every state.
type TransitionMap = IntMap (IntMap State)
type FallbackMap = IntMap State
type ValuesMap v = IntMap [v]

-- | Build the trie of the Aho-Corasick state machine for all input needles.
buildTransitionMap :: forall v. [([CodeUnit], v)] -> (Int, TransitionMap, ValuesMap v)
buildTransitionMap =
  let
    -- | Inserts a single needle into the given transition and values map.
    -- Int is used to keep track of the current number of states.
    go :: State
      -> (Int, TransitionMap, ValuesMap v)
      -> ([CodeUnit], v)
      -> (Int, TransitionMap, ValuesMap v)

    -- End of the current needle, insert the associated payload value.
    -- If a needle occurs multiple times, then at this point we will merge
    -- their payload values, so the needle is reported twice, possibly with
    -- different payload values.
    go !state (!numStates, transitions, values) ([], v) =
      (numStates, transitions, IntMap.insertWith (++) state [v] values)

    -- Follow the edge for the given input from the current state, creating it
    -- if it does not exist.
    go !state (!numStates, transitions, values) (input : needleTail, vs) =
      let
        transitionsFromState = transitions IntMap.! state
      in
        case IntMap.lookup (fromIntegral input) transitionsFromState of
          Just nextState ->
            go nextState (numStates, transitions, values) (needleTail, vs)
          Nothing ->
            let
              -- Allocate a new state, and insert a transition to it.
              -- Also insert an empty transition map for it.
              nextState = numStates
              transitionsFromState' = IntMap.insert (fromIntegral input) nextState transitionsFromState
              transitions'
                = IntMap.insert state transitionsFromState'
                $ IntMap.insert nextState IntMap.empty transitions
            in
              go nextState (numStates + 1, transitions', values) (needleTail, vs)

    -- Initially, the root state (state 0) exists, and it has no transitions
    -- to anywhere.
    stateInitial = 0
    initialTransitions = IntMap.singleton stateInitial IntMap.empty
    initialValues = IntMap.empty
    insertNeedle = go stateInitial
  in
    foldl' insertNeedle (1, initialTransitions, initialValues)

-- Size of the ascii transition lookup table.
asciiCount :: Integral a => a
asciiCount = 128

-- | Build a lookup table for the first 128 code units, that can be used for
-- O(1) lookup of a transition, rather than doing a linear scan over all
-- transitions. The fallback goes back to the initial state, state 0.
buildAsciiTransitionLookupTable :: IntMap State -> UVector.Vector Transition
buildAsciiTransitionLookupTable transitions = UVector.generate asciiCount $ \i ->
  case IntMap.lookup i transitions of
    Just state -> newTransition (fromIntegral i) state
    Nothing    -> newWildcardTransition 0

-- | Traverse the state trie in breadth-first order.
foldBreadthFirst :: (a -> State -> a) -> a -> TransitionMap -> a
foldBreadthFirst f seed transitions = go [0] [] seed
  where
    -- For the traversal, we keep a queue of states to vitit. Every iteration we
    -- take one off the front, and all states reachable from there get added to
    -- the back. Rather than using a list for this, we use the functional
    -- amortized queue to avoid O(n²) append. This makes a measurable difference
    -- when the backlog can grow large. In one of our benchmark inputs for
    -- example, we have roughly 160 needles that are 10 characters each (but
    -- with some shared prefixes), and the backlog size grows to 148 during
    -- construction. Construction time goes down from ~0.80 ms to ~0.35 ms by
    -- using the amortized queue.
    -- See also section 3.1.1 of Purely Functional Data Structures by Okasaki
    -- https://www.cs.cmu.edu/~rwh/theses/okasaki.pdf.
    go [] [] !acc = acc
    go [] revBacklog !acc = go (reverse revBacklog) [] acc
    go (state : backlog) revBacklog !acc =
      let
        -- Note that the backlog never contains duplicates, because we traverse
        -- a trie that only branches out. For every state, there is only one
        -- path from the root that leads to it.
        extra = IntMap.elems $ transitions IntMap.! state
      in
        go backlog (extra ++ revBacklog) (f acc state)

-- | Determine the fallback transition for every state, by traversing the
-- transition trie breadth-first.
buildFallbackMap :: TransitionMap -> FallbackMap
buildFallbackMap transitions =
  let
    -- Suppose that in state `state`, there is a transition for input `input`
    -- to state `nextState`, and we already know the fallback for `state`. Then
    -- this function returns the fallback state for `nextState`.
    getFallback :: FallbackMap -> State -> Int -> State
    -- All the states after the root state (state 0) fall back to the root state.
    getFallback _ 0 _ = 0
    getFallback fallbacks !state !input =
      let
        fallback = fallbacks IntMap.! state
        transitionsFromFallback = transitions IntMap.! fallback
      in
        case IntMap.lookup input transitionsFromFallback of
          Just st -> st
          Nothing -> getFallback fallbacks fallback input

    insertFallback :: State -> FallbackMap -> Int -> State -> FallbackMap
    insertFallback !state fallbacks !input !nextState =
      IntMap.insert nextState (getFallback fallbacks state input) fallbacks

    insertFallbacks :: FallbackMap -> State -> FallbackMap
    insertFallbacks fallbacks !state =
      IntMap.foldlWithKey' (insertFallback state) fallbacks (transitions IntMap.! state)
  in
    foldBreadthFirst insertFallbacks (IntMap.singleton 0 0) transitions

-- | Determine which matches to report at every state, by traversing the
-- transition trie breadth-first, and appending all the matches from a fallback
-- state to the matches for the current state.
buildValueMap :: forall v. TransitionMap -> FallbackMap -> ValuesMap v -> ValuesMap v
buildValueMap transitions fallbacks valuesInitial =
  let
    insertValues :: ValuesMap v -> State -> ValuesMap v
    insertValues values !state =
      let
        fallbackValues = values IntMap.! (fallbacks IntMap.! state)
        valuesForState = case IntMap.lookup state valuesInitial of
          Just vs -> vs ++ fallbackValues
          Nothing -> fallbackValues
      in
        IntMap.insert state valuesForState values
  in
    foldBreadthFirst insertValues (IntMap.singleton 0 []) transitions

-- Define aliases for array indexing so we can turn bounds checks on and off
-- in one place. We ran this code with `Vector.!` (bounds-checked indexing) in
-- production for two months without failing the bounds check, so we have turned
-- the check off for performance now.
at :: forall a. Vector.Vector a -> Int -> a
at = Vector.unsafeIndex

uAt :: forall a. UVector.Unbox a => UVector.Vector a -> Int -> a
uAt = UVector.unsafeIndex

-- RUNNING THE MACHINE

-- | Result of handling a match: stepping the automaton can exit early by
-- returning a `Done`, or it can continue with a new accumulator with `Step`.
data Next a = Done !a | Step !a

-- | Run the automaton, possibly lowercasing the input text on the fly if case
-- insensitivity is desired. See also `runLower`.
--
-- The code of this function itself is organized as a state machine as well.
-- Each state in the diagram below corresponds to a function defined in
-- `runWithCase`. These functions are written in a way such that GHC identifies them
-- as [join points](https://www.microsoft.com/en-us/research/publication/compiling-without-continuations/).
-- This means that they can be compiled to jumps instead of function calls, which helps performance a lot.
--
-- @
-- ┌────────────┐   ┌────────────────┐
-- │consumeInput├───►followCodeUnits │
-- └─▲──────────┘   └─▲────────────┬─┘
--   │                │            │
--   │              ┌─┴────────────▼─┐   ┌──────────────┐
--   │              │lookupTransition├───►collectMatches│
--   │              └────▲──────┬────┘   └────────────┬─┘
--   │                   │      │                     │
--   │                   └──────┘                     │
--   │                                                │
--   └────────────────────────────────────────────────┘
-- @
--
-- * @consumeInput@ inspects the next code unit in the input and decides what to do with it.
--   If necessary, it decodes a code point of up to four code units and passes them to @followCodeUnits@.
-- * @followCodeUnits@ pops an entry from the code unit queue and passes it to @lookupTransition@.
-- * @lookupTransition@ checks whether the given code unit matches any transitions at the given state.
--   If so, it follows the transition and then loops back to @followCodeUnits@ if the code unit queue
--   is not empty and otherwise calls @collectMatches@.
-- * @collectMatches@ checks whether the current state is accepting and updates the accumulator accordingly.
--   Afterwards it loops back to @consumeInput@.
--
-- NOTE: @followCodeUnits@ is actually inlined into @consumeInput@ and @lookupTransition@ by GHC.
-- It is included in the diagram for illustrative reasons only.
--
-- All of these functions have the arguments @offset@, @remaining@ and @acc@ which encode the current input
-- position and the accumulator, which contains the matches.
-- Functions in the loop including @followCodeUnits@ and @lookupTransition@ also contain arguments for the
-- code unit queue. Currently, the code unit queue is implemented as a single `Word32` argument which
-- contains 0-4 packed code units.
--
-- WARNING: Run benchmarks when modifying this function; its performance is
-- fragile. It took many days to discover the current formulation which compiles
-- to fast code; removing the wrong bang pattern could cause a 10% performance
-- regression.
{-# INLINE runWithCase #-}
runWithCase :: forall a v. CaseSensitivity -> a -> (a -> Match v -> Next a) -> AcMachine v -> Text -> a
runWithCase !caseSensitivity !seed !f !machine !text =
  consumeInput initialOffset initialRemaining seed initialState
  where
    initialState = 0

    Text !u8data !initialOffset !initialRemaining = text
    AcMachine !values !transitions !offsets !rootAsciiTransitions = machine

    -- NOTE: All of the arguments are strict here, because we want to compile
    -- them down to unpacked variables on the stack, or even registers.

    -- When we follow an edge, we look in the transition table and do a
    -- linear scan over all transitions until we find the right one, or
    -- until we hit the wildcard transition at the end. For 0 or 1 or 2
    -- transitions that is fine, but the initial state often has more
    -- transitions, so we have a dedicated lookup table for it, that takes
    -- up a bit more space, but provides O(1) lookup of the next state. We
    -- only do this for the first 128 code units (all of ascii).

    -- | Consume a code unit sequence that constitutes a full code point.
    -- If the code unit at @offset@ is ASCII, we can lower it using 'Utf8.toLowerAscii'.
    -- Otherwise we have to assume that lowercasing it will change the length of the code unit sequence.
    -- Therefore we have to invoke @followCodeUnits@, which keeps a queue of code units and looks up their transitions one after the other.
    {-# NOINLINE consumeInput #-}
    consumeInput :: Int -> Int -> a -> State -> a
    consumeInput _offset 0 acc _state = acc
    consumeInput !offset !remaining !acc !state =
      case caseSensitivity of
        -- If we are doing case sensitive matching, we can just use the unmodified
        -- input code units.
        CaseSensitive ->
          if cu < asciiCount && state == initialState
            then lookupRootAsciiTransition (offset + 1) (remaining - 1) acc cu
            else followCodeUnit (offset + 1) (remaining - 1) acc cu state

        IgnoreCase
          -- Code point is a single byte ==> It's ASCII, no need to call toLower; we can just use maths :)
          -- We could check < asciiCount here as well, since there are no UTF-8 code unit sequences starting with 10xxxxxx
          | cu < 0xc0 ->
            let
              !cu' = Utf8.toLowerAscii cu
            in
              if state == initialState
                then lookupRootAsciiTransition (offset + 1) (remaining - 1) acc cu'
                else followCodeUnit (offset + 1) (remaining - 1) acc cu' state

          -- Code point is two bytes ==> decode and lowercase
          | cu < 0xe0 -> followLowerCodePoint (offset + 2) (remaining - 2) acc (Utf8.decode2 cu $ indexTextArray u8data $ offset + 1) state

          -- Code point is three bytes ==> decode and lowercase
          | cu < 0xf0 -> followLowerCodePoint (offset + 3) (remaining - 3) acc (Utf8.decode3 cu (indexTextArray u8data $ offset + 1) (indexTextArray u8data $ offset + 2)) state

          -- Code point is four bytes ==> decode and lowercase
          -- NOTE: This implementation is not entirely the same as the UTF-16 one since it also handles code points outside the BMP.
          | otherwise -> followLowerCodePoint (offset + 4) (remaining - 4) acc (Utf8.decode4 cu (indexTextArray u8data $ offset + 1) (indexTextArray u8data $ offset + 2) (indexTextArray u8data $ offset + 3)) state

      where
        !cu = indexTextArray u8data offset

    -- | Lowers the given code point, translates it back into code units and follows those.
    {-# INLINE followLowerCodePoint #-}
    followLowerCodePoint :: Int -> Int -> a -> Int -> State -> a
    followLowerCodePoint !offset !remaining !acc !cp !state
      | lowerCp < 0x80 = followCodeUnit offset remaining acc (fromIntegral lowerCp) state
      | lowerCp < 0x800 = follow2CodeUnits offset remaining acc (0xc0 .|. fromIntegral (lowerCp `shiftR` 6)) (0x80 .|. fromIntegral (lowerCp .&. 0x3f)) state
      | lowerCp < 0x10000 = follow3CodeUnits offset remaining acc (0xe0 .|. fromIntegral (lowerCp `shiftR` 12)) (0x80 .|. fromIntegral ((lowerCp `shiftR` 6) .&. 0x3f)) (0x80 .|. fromIntegral (lowerCp .&. 0x3f)) state
      | otherwise = follow4CodeUnits offset remaining acc (0xf0 .|. fromIntegral (lowerCp `shiftR` 18)) (0x80 .|. fromIntegral (lowerCp `shiftR` 12)) (0x80 .|. fromIntegral ((lowerCp `shiftR` 6) .&. 0x3f)) (0x80 .|. fromIntegral (lowerCp .&. 0x3f)) state
      where
        !lowerCp = Char.ord $ Char.toLower $ Char.chr cp

    -- | Follows 1-4 code units packed into a Word32.
    {-# INLINE followCodeUnits #-}
    followCodeUnits :: Int -> Int -> a -> Word32 -> State -> a
    followCodeUnits !offset !remaining !acc !cus !state =
      followEdge offset remaining acc cu0 cus' state
      where
        cu0 = fromIntegral $ cus .&. 0xff
        cus' = cus `shiftR` 8

    {-# INLINE followEdge #-}
    followEdge :: Int -> Int -> a -> CodeUnit -> Word32 -> State -> a
    followEdge !offset !remaining !acc !cu !cus !state =
      lookupTransition offset remaining acc cu cus state $ offsets `uAt` state

    -- NOTE: there is no `state` argument here, because this case applies only
    -- to the root state `stateInitial`.
    {-# INLINE lookupRootAsciiTransition #-}
    lookupRootAsciiTransition !offset !remaining !acc !cu
      -- Given code unit does not match at root ==> Repeat at offset from initial state
      | transitionIsWildcard t = consumeInput offset remaining acc initialState
      -- Transition matched!
      | otherwise = collectMatches offset remaining acc $ transitionState t
      where !t = rootAsciiTransitions `uAt` fromIntegral cu

    -- NOTE: This function can't be inlined since it is self-recursive.
    {-# NOINLINE lookupTransition #-}
    lookupTransition :: Int -> Int -> a -> CodeUnit -> Word32 -> State -> Int -> a
    lookupTransition !offset !remaining !acc !cu !cus !state !i
      -- There is no transition for the given input. Follow the fallback edge,
      -- and try again from that state, etc. If we are in the base state
      -- already, then nothing matched, so move on to the next input.
      | transitionIsWildcard t =
        if state == initialState
          then consumeInput offset remaining acc state
          else followEdge offset remaining acc cu cus (transitionState t)
      -- We found the transition, switch to that new state, possibly matching the rest of cus.
      -- NOTE: This comes after wildcard checking, because the code unit of
      -- the wildcard transition is 0, which is a valid input.
      | transitionCodeUnit t == cu =
        if cus == 0
          then collectMatches offset remaining acc (transitionState t)
          else followCodeUnits offset remaining acc cus (transitionState t)
      -- The transition we inspected is not for the current input, and it is not
      -- a wildcard either; look at the next transition then.
      | otherwise =
        lookupTransition offset remaining acc cu cus state $ i + 1

      where
        !t = transitions `uAt` i

    -- TODO: In this case, we could avoid the loop in loookupTransition completely and just follow a single edge.
    -- Should be worth investigating but could lead to some code duplication.
    {-# INLINE followCodeUnit #-}
    followCodeUnit :: Int -> Int -> a -> CodeUnit -> State -> a
    followCodeUnit !offset !remaining !acc !cu0 !state =
      followEdge offset remaining acc (fromIntegral cu0) 0 state

    {-# INLINE follow2CodeUnits #-}
    follow2CodeUnits :: Int -> Int -> a -> CodeUnit -> CodeUnit -> State -> a
    follow2CodeUnits !offset !remaining !acc !cu0 !cu1 !state =
      followCodeUnits offset remaining acc (fromIntegral cu0 .|. fromIntegral cu1 `shiftL` 8) state

    {-# INLINE follow3CodeUnits #-}
    follow3CodeUnits :: Int -> Int -> a -> CodeUnit -> CodeUnit -> CodeUnit -> State -> a
    follow3CodeUnits !offset !remaining !acc !cu0 !cu1 !cu2 !state =
      followCodeUnits offset remaining acc (fromIntegral cu0 .|. fromIntegral cu1 `shiftL` 8 .|. fromIntegral cu2 `shiftL` 16) state

    {-# INLINE follow4CodeUnits #-}
    follow4CodeUnits :: Int -> Int -> a -> CodeUnit -> CodeUnit -> CodeUnit -> CodeUnit -> State -> a
    follow4CodeUnits !offset !remaining !acc !cu0 !cu1 !cu2 !cu3 !state =
      followCodeUnits offset remaining acc (fromIntegral cu0 .|. fromIntegral cu1 `shiftL` 8 .|. fromIntegral cu2 `shiftL` 16 .|. fromIntegral cu3 `shiftL` 24) state

    {-# NOINLINE collectMatches #-}
    collectMatches !offset !remaining !acc !state =
      let
        matchedValues = values `at` state
        -- Fold over the matched values. If at any point the user-supplied fold
        -- function returns `Done`, then we early out. Otherwise continue.
        handleMatch !acc' vs = case vs of
          []     -> consumeInput offset remaining acc' state
          v:more -> case f acc' (Match (CodeUnitIndex $ offset - initialOffset) v) of
            Step newAcc -> handleMatch newAcc more
            Done finalAcc -> finalAcc
      in
        handleMatch acc matchedValues

-- NOTE: To get full advantage of inlining this function, you probably want to
-- compile the compiling module with -fllvm and the same optimization flags as
-- this module.
{-# INLINE runText #-}
runText :: forall a v. a -> (a -> Match v -> Next a) -> AcMachine v -> Text -> a
runText = runWithCase CaseSensitive

-- Finds all matches in the lowercased text. This function lowercases the input text
-- on the fly to avoid allocating a second lowercased text array.  It is still the
-- responsibility of  the caller to lowercase the needles. Needles that contain
-- uppercase code  points will not match.
--
-- NOTE: To get full advantage of inlining this function, you probably want to
-- compile the compiling module with -fllvm and the same optimization flags as
-- this module.
{-# INLINE runLower #-}
runLower :: forall a v. a -> (a -> Match v -> Next a) -> AcMachine v -> Text -> a
runLower = runWithCase IgnoreCase
