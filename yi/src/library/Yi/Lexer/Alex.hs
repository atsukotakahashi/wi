-- | Utilities to turn a lexer generated by Alex into a scanner
--   that can be used by Yi.
{-# LANGUAGE Rank2Types, DeriveFunctor #-}
module Yi.Lexer.Alex (
                       -- * Names expected by Alex code
                       AlexInput,
                       alexGetChar, alexInputPrevChar,

                       -- * Other things closely associated with the lexer
                       AlexState(..),
                       unfoldLexer, lexScanner,
                       alexCollectChar,

                       -- * Lexer actions
                       actionConst, actionAndModify, actionStringAndModify, actionStringConst,

                       -- * Data produced by the scanner
                       Tok(..), tokBegin, tokEnd, tokFromT, tokRegion,
                       Posn(..), startPosn, moveStr,
                       ASI,
                       (+~), (~-), Size(..),
                       Stroke,
                       tokToSpan,
                       alexGetByte
                      ) where

import Yi.Syntax hiding (mkHighlighter)

import Yi.Region
import Data.Ord (comparing)
import Data.Ix
import Data.Word (Word8)
import Data.Char (ord)
import Data.List (foldl')
import Yi.Utils

type IndexedStr = [(Point, Char)]
type AlexInput = (Char, IndexedStr)
type Action hlState token = IndexedStr -> hlState -> (hlState, token)

-- | Lexer state
data AlexState lexerState = AlexState {
      stLexer  :: lexerState,   -- (user defined) lexer state
      lookedOffset :: !Point, -- Last offset looked at
      stPosn :: !Posn
    } deriving Show

data Tok t = Tok
    {
     tokT :: t,
     tokLen  :: Size,
     tokPosn :: Posn
    } deriving Functor

tokToSpan :: Tok t -> Span t
tokToSpan (Tok t len posn) = Span (posnOfs posn) t (posnOfs posn +~ len)

tokFromT :: forall t. t -> Tok t
tokFromT t = Tok t 0 startPosn

tokBegin :: forall t. Tok t -> Point
tokBegin = posnOfs . tokPosn

tokEnd :: forall t. Tok t -> Point
tokEnd t = tokBegin t +~ tokLen t

tokRegion :: Tok t -> Region
tokRegion t = mkRegion (tokBegin t) (tokEnd t)


instance Show t => Show (Tok t) where
    show tok = show (tokPosn tok) ++ ": " ++ show (tokT tok)

data Posn = Posn {
      posnOfs :: !Point
    , posnLine :: !Int
    , posnCol :: !Int
  } deriving (Eq, Ix)

-- TODO: Verify that this is right.  /Deniz
instance Ord Posn where
    compare = comparing posnOfs

instance Show Posn where
    show (Posn o l c) = "L" ++ show l ++ " " ++ "C" ++ show c ++ "@" ++ show o

startPosn :: Posn
startPosn = Posn 0 1 0


moveStr :: Posn -> IndexedStr -> Posn
moveStr posn str = foldl' moveCh posn (fmap snd str)

moveCh :: Posn -> Char -> Posn
moveCh (Posn o l c) '\t' = Posn (o+1) l       (((c+8) `div` 8)*8)
moveCh (Posn o l _) '\n' = Posn (o+1) (l+1)   0
moveCh (Posn o l c) _    = Posn (o+1) l       (c+1)

alexGetChar :: AlexInput -> Maybe (Char, AlexInput)
alexGetChar (_,[]) = Nothing
alexGetChar (_,(_,c):rest) = Just (c, (c,rest))

first :: (a -> b) -> (a, c) -> (b, c)
first f (a, c) = (f a, c)

alexGetByte :: AlexInput -> Maybe (Word8, AlexInput)
alexGetByte = fmap (first (fromIntegral . ord)) . alexGetChar

{-# ANN alexCollectChar "HLint: ignore Use String" #-}
alexCollectChar :: AlexInput -> [Char]
alexCollectChar (_, []) = []
alexCollectChar (_, (_,c):rest) = c : alexCollectChar (c,rest)

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar (prevChar,_) = prevChar

-- | Return a constant token
actionConst :: token -> Action lexState token
actionConst token _str state = (state, token)

-- | Return a constant token, and modify the lexer state
actionAndModify :: (lexState -> lexState) -> token -> Action lexState token
actionAndModify modifierFct token _str state = (modifierFct state, token)

-- | Convert the parsed string into a token,
--   and also modify the lexer state
actionStringAndModify :: (lexState -> lexState) -> (String ->token) -> Action lexState token
actionStringAndModify modifierFct f indexedStr state = (modifierFct state, f $ fmap snd indexedStr)

-- | Convert the parsed string into a token
actionStringConst :: (String -> token) -> Action lexState token
actionStringConst f indexedStr state = (state, f $ fmap snd indexedStr)

type ASI s = (AlexState s, AlexInput)

-- | Combine a character scanner with a lexer to produce a token scanner.
--   May be used together with 'mkHighlighter' to produce a 'Highlighter',
--   or with 'linearSyntaxMode' to produce a 'Mode'.
lexScanner :: forall lexerState token.
                                          ((AlexState lexerState, AlexInput)
                                           -> Maybe (token, (AlexState lexerState, AlexInput))) -- ^ A lexer
                                          -> lexerState -- ^ Initial user state for the lexer
                                          -> Scanner Point Char
                                          -> Scanner (AlexState lexerState) token
lexScanner l st0 src = Scanner
                 {
                  --stStart = posnOfs . stPosn,
                  scanLooked = lookedOffset,
                  scanInit = AlexState st0 0 startPosn,
                  scanRun = \st ->
                     case posnOfs $ stPosn st of
                         0 -> unfoldLexer l (st, ('\n', scanRun src 0))
                         ofs -> case scanRun src (ofs - 1) of
                             -- FIXME: if this is a non-ascii char the ofs. will be wrong.
                             -- However, since the only thing that matters (for now) is 'is the previous char a new line', we don't really care.
                             -- (this is to support ^,$ in regexes)
                             [] -> []
                             ((_,ch):rest) -> unfoldLexer l (st, (ch, rest))
                  , scanEmpty = error "Yi.Lexer.Alex.lexScanner: scanEmpty"
                 }

-- | unfold lexer function into a function that returns a stream of (state x token)
unfoldLexer :: ((AlexState lexState, input) -> Maybe (token, (AlexState lexState, input)))
             -> (AlexState lexState, input) -> [(AlexState lexState, token)]
unfoldLexer f b = case f b of
             Nothing -> []
             Just (t, b') -> (fst b, t) : unfoldLexer f b'
