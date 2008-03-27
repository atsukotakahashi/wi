{-# OPTIONS -fglasgow-exts #-}

module Yi.Syntax.Alex (
                       Source(..),
                       mkHighlighter, 
                       alexGetChar, alexInputPrevChar, unfoldLexer, lexerSource,
                       AlexState(..), AlexInput, Stroke,
                       takeLB, headLB, actionConst, actionAndModify,
                       Tok(..), Posn(..), startPosn, moveStr, runSource) where

import Data.List hiding (map)
import qualified Data.ByteString.Lazy.Char8 as LB
import Yi.Syntax
import Yi.Prelude
import Prelude ()

takeLB :: Int64 -> LB.ByteString -> LB.ByteString
takeLB = LB.take

headLB :: LB.ByteString -> Char
headLB = LB.head


type LookedOffset = Int -- ^ if offsets before this is dirtied, must restart from that state.
type AlexInput  = LB.ByteString
type Action hlState token = AlexInput -> hlState -> (hlState, token)
type State hlState = (AlexState hlState, [Stroke]) -- ^ Lexer state; (reversed) list of tokens so far.
data AlexState lexerState = AlexState { 
      stLexer  :: lexerState,   -- (user defined) lexer state
      lookedOffset :: !LookedOffset, -- Last offset looked at
      stPosn :: !Posn
    }

data Tok t = Tok
    {
     tokT :: t,
     tokLen  :: Int,
     tokPosn :: Posn
    }

instance Show t => Show (Tok t) where
    show tok = show (tokPosn tok) ++ ": " ++ show (tokT tok)              

type Result = ([Stroke], [Stroke])

data Posn = Posn {posnOfs :: !Int, posnLine :: !Int, posnCol :: !Int}

instance Show Posn where
    show (Posn _ l c) = "L" ++ show l ++ " " ++ "C" ++ show c

startPosn :: Posn
startPosn = Posn 0 1 0

moveStr :: Posn -> LB.ByteString -> Posn
moveStr posn str = foldl' moveCh posn (LB.unpack str)

moveCh :: Posn -> Char -> Posn
moveCh (Posn o l c) '\t' = Posn (o+1)  l     (((c+8) `div` 8)*8)
moveCh (Posn o l _) '\n' = Posn (o+1) (l+1)   0
moveCh (Posn o l c) _    = Posn (o+1) l     (c+1) 


alexGetChar :: AlexInput -> Maybe (Char, AlexInput)
alexGetChar bs | LB.null bs = Nothing
               | otherwise  = Just (LB.head bs, LB.tail bs)

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar = undefined

actionConst :: token -> Action lexState token
actionConst token _str state = (state, token)

actionAndModify :: (lexState -> lexState) -> token -> Action lexState token
actionAndModify modifier token _str state = (modifier state, token)

data Cache s = Cache [State s] Result

-- Unfold, scanl and foldr at the same time :)
origami :: (b -> Maybe (a, b)) -> b -> (a -> c -> c) -> (c -> a -> c) 
        -> c -> c -> ([(b, c)], c)
origami gen seed (<+) (+>) l_c r_c = case gen seed of
      Nothing -> ([], r_c)
      Just (a, new_seed) -> 
          let ~(partials,c) = origami gen new_seed (<+) (+>) (l_c +> a) r_c
          in ((seed,l_c):partials,l_c `seq` a <+ c)

type ASI s = (AlexState s, AlexInput)

-- | Highlighter based on an Alex lexer 
mkHighlighter :: forall s. s
              -> (ASI s -> Maybe (Stroke, ASI s))
              -> Yi.Syntax.Highlighter (Cache s)
mkHighlighter initState alexScanToken = 
  Yi.Syntax.SynHL { hlStartState   = Cache [] ([],[])
                  , hlRun          = run
                  , hlGetStrokes   = getStrokes
                  }
      where 
        startState = (AlexState initState 0 startPosn, [])
        getStrokes begin end (Cache _ (leftHL, rightHL)) = reverse (usefulsL leftHL) ++ usefulsR rightHL
            where
              usefulsR = dropWhile (\(_l,_s,r) -> r <= begin) .
                        takeWhile (\(l,_s,_r) -> l <= end)
                        
              usefulsL = dropWhile (\(l,_s,_r) -> l >= end) .
                         takeWhile (\(_l,_s,r) -> r >= begin)

        run getInput dirtyOffset (Cache cachedStates _) = -- trace (show $ map trd3 $ newCachedStates) $
            Cache newCachedStates result
            where resumeIndex = posnOfs $ stPosn $ fst $ resumeState
                  reused = takeWhile ((< dirtyOffset) . lookedOffset . fst) cachedStates
                  resumeState = if null reused then startState else last reused
                  newCachedStates = reused ++ other 20 0 (drop 1 recomputed)
                  (recomputed, result) = updateState text resumeState
                  text = getInput resumeIndex


        updateState :: AlexInput -> State s -> ([State s], Result)
        updateState input (restartState, startPartial) = 
            (map f partials, (startPartial, result))
                where result :: [Stroke]
                      (partials,result) = origami alexScanToken (restartState, input) (:) (flip (:)) startPartial []
                      f :: ((AlexState s, AlexInput), [Stroke]) -> State s
                      f ((s, _), partial) = (s, partial)

other :: Int -> Int -> [a] -> [a]
other n m l = case l of
                [] -> []
                (h:t) ->
                    case m of
                      0 -> h:other n n     t
                      _ ->   other n (m-1) t

-- | unfold lexer function into a function that returns a stream of (state x token)
unfoldLexer :: ((AlexState lexState, input) -> Maybe (token, (AlexState lexState, input)))
             -> (AlexState lexState, input) -> [(AlexState lexState, token)]
unfoldLexer f b = case f b of
             Nothing -> []
             Just (t, b') -> (fst b, t) : unfoldLexer f b'

