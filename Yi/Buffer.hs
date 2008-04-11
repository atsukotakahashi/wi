{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable, StandaloneDeriving, ExistentialQuantification, Rank2Types #-}

-- Copyright (C) 2004, 2008 Don Stewart - http://www.cse.unsw.edu.au/~dons

-- | The 'Buffer' module defines monadic editing operations over one-dimensional
-- buffers, which maintain a current /point/.

module Yi.Buffer
  ( BufferRef
  , FBuffer       ( .. )
  , BufferM       ( .. )
  , runBuffer
  , runBufferDummyWindow
  , keyB
  , curLn
  , sizeB
  , pointB
  , moveTo
  , lineMoveRel
  , lineUp
  , lineDown
  , newB
  , Point
  , Mark
  , gotoLn
  , gotoLnFrom
  , offsetFromSol
  , leftB
  , rightB
--  , moveN
  , leftN
  , rightN
  , insertN
  , insertNAt
  , insertB
  , deleteN
  , nelemsB
  , writeB
  , getfileB
  , setfileB
  , setnameB
  , deleteNAt
  , readB
  , elemsB
  , undosA
  , undoB
  , redoB
  , getMarkB
  , getSelectionMarkB
  , pointSelectionPointDiffB
  , getMarkPointB
  , setMarkPointB
  , setVisibleSelection
  , isUnchangedB
  , isUnchangedBuffer
  , setMode
  , regexB
  , searchB
  , readAtB
  , getModeLine
  , getPercent
  , forgetPreferCol
  , clearUndosB
  , addOverlayB
  , getDynamicB
  , setDynamicB
  , nelemsBH
  , styleRangesB
  , Direction        ( .. )
  , savingExcursionB
  , savingPointB
  , pendingUpdatesA
  , highlightSelectionA
  , revertPendingUpdatesB
  , askWindow
  , clearSyntax
  , Mode (..)
  , AnyMode(..)
  , emptyMode
  , withModeB
  , withSyntax0
  )
where

import Prelude hiding (error)
import Yi.Debug
import System.FilePath
import Text.Regex.Posix.Wrap    (Regex)
import Yi.Accessor
import Yi.Buffer.Implementation
import Yi.Syntax
import Yi.Undo
import Yi.Style
import Yi.Dynamic
import Yi.Window
import Control.Applicative
import Control.Monad.RWS.Strict
import Data.List (elemIndex)
import Data.Typeable
import {-# source #-} Yi.Keymap
import Yi.Monad

#ifdef TESTING
import Test.QuickCheck
import Driver ()

instance Arbitrary FBuffer where
    arbitrary = do b0 <- return (newB 0 "*buffername*") `ap` arbitrary
                   p0 <- arbitrary
                   return $ snd $ runBufferDummyWindow b0 (moveTo p0)

-- TODO: make this compile.
-- prop_replace_point b = snd $ runBufferDummyWindow b $ do
--   p0 <- pointB
--   replaceRegionB r
--   p1 <- pointB
--   return $ (p1 - p0) == ...
#endif

-- In addition to Buffer's text, this manages (among others):
--  * Log of updates mades
--  * Undo


data FBuffer = forall syntax.
        FBuffer { name   :: !String               -- ^ immutable buffer name
                , bkey   :: !BufferRef            -- ^ immutable unique key
                , file   :: !(Maybe FilePath)     -- ^ maybe a filename associated with this buffer. Filename is canonicalized.
                , undos  :: !URList               -- ^ undo/redo list
                , rawbuf :: !(BufferImpl syntax)
                , bmode  :: !(Mode syntax)
                , readOnly :: Bool -- ^ a read-only bit
                , bufferDynamic :: !DynamicValues -- ^ dynamic components
                , preferCol :: !(Maybe Int)       -- ^ prefered column to arrive at when we do a lineDown / lineUp
                , pendingUpdates :: [Update]       -- ^ updates that haven't been synched in the UI yet
                , highlightSelection :: !Bool
                }
        deriving Typeable

clearSyntax :: FBuffer -> FBuffer
clearSyntax = modifyRawbuf updateSyntax


modifyRawbuf :: (forall syntax. BufferImpl syntax -> BufferImpl syntax) -> FBuffer -> FBuffer
modifyRawbuf f (FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11) = 
    (FBuffer f1 f2 f3 f4 (f f5) f6 f7 f8 f9 f10 f11)

queryAndModifyRawbuf :: (forall syntax. BufferImpl syntax -> (BufferImpl syntax,x)) ->
                     FBuffer -> (FBuffer, x)
queryAndModifyRawbuf f (FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11) = 
    let (f5', x) = f f5
    in (FBuffer f1 f2 f3 f4 f5' f6 f7 f8 f9 f10 f11, x)

undosA :: Accessor (FBuffer) (URList)
undosA = Accessor undos (\f e -> case e of 
                                   FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 -> 
                                    FBuffer f1 f2 f3 (f f4) f5 f6 f7 f8 f9 f10 f11)

fileA :: Accessor (FBuffer) (Maybe FilePath)
fileA = Accessor file (\f e -> case e of 
                                   FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 -> 
                                    FBuffer f1 f2 (f f3) f4 f5 f6 f7 f8 f9 f10 f11)

preferColA :: Accessor (FBuffer) (Maybe Int)
preferColA = Accessor preferCol (\f e -> case e of 
                                   FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 -> 
                                    FBuffer f1 f2 f3 f4 f5 f6 f7 f8 (f f9) f10 f11)

bufferDynamicA :: Accessor (FBuffer) (DynamicValues)
bufferDynamicA = Accessor bufferDynamic (\f e -> case e of 
                                   FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 -> 
                                    FBuffer f1 f2 f3 f4 f5 f6 f7 (f f8) f9 f10 f11)

pendingUpdatesA :: Accessor (FBuffer) ([Update])
pendingUpdatesA = Accessor pendingUpdates (\f e -> case e of 
                                   FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 -> 
                                    FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 (f f10) f11)

highlightSelectionA :: Accessor FBuffer Bool
highlightSelectionA = Accessor highlightSelection (\f e -> case e of 
                                   FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 -> 
                                    FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 (f f11))

nameA :: Accessor FBuffer String
nameA = Accessor name (\f e -> case e of 
                                   FBuffer f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 -> 
                                    FBuffer (f f1) f2 f3 f4 f5 f6 f7 f8 f9 f10 f11)


data AnyMode = forall syntax. AnyMode (Mode syntax)

data Mode syntax = Mode
    {
     -- modeName = "fundamental", -- ^ so this could be serialized, debugged.
     modeHL :: ExtHL syntax,
     modeKeymap :: KeymapEndo, -- ^ Buffer's local keymap modification
     modeIndent :: BufferM (),
     modeTestUseAst :: syntax -> BufferM ()
    }



-- | The BufferM monad writes the updates performed.
newtype BufferM a = BufferM { fromBufferM :: RWS Window [Update] FBuffer a }
    deriving (Monad, Functor, MonadWriter [Update], MonadState FBuffer, MonadReader Window, Typeable1)

deriving instance Typeable4 RWS

instance Applicative BufferM where
    pure = return
    af <*> ax = do
      f <- af
      x <- ax
      return (f x)

instance Eq FBuffer where
   FBuffer { bkey = u } == FBuffer { bkey = v } = u == v

instance Show FBuffer where
    showsPrec _ (FBuffer { bkey = u, name = f, undos = us }) = showString $ "Buffer #" ++ show u ++ " (" ++ show f ++ "..." ++ show us ++ ")"

-- | Given a buffer, and some information update the modeline
--
-- N.B. the contents of modelines should be specified by user, and
-- not hardcoded.
--
getModeLine :: BufferM String
getModeLine = do
    col <- offsetFromSol
    pos <- pointB
    ln <- curLn
    p <- pointB
    s <- sizeB
    unchanged <- isUnchangedB
    let pct = if pos == 1 then "Top" else getPercent p s
        chg = if unchanged then "-" else "*"
    nm <- gets name
    return $
           chg ++ " "
           ++ nm ++
           replicate 5 ' ' ++
           "L" ++ show ln ++ "  " ++ "C" ++ show col ++
           "  " ++ pct ++
           "  " ++ show p

--
-- | Give a point, and the file size, gives us a percent string
--
getPercent :: Int -> Int -> String
getPercent a b = show p ++ "%"
    where p = ceiling ((fromIntegral a) / (fromIntegral b) * 100 :: Double) :: Int

queryBuffer :: (forall syntax. BufferImpl syntax -> x) -> (BufferM x)
queryBuffer f = gets (\(FBuffer _ _ _ _ fb _ _ _ _ _ _) -> f fb)

modifyBuffer :: (forall syntax. BufferImpl syntax -> BufferImpl syntax) -> BufferM ()
modifyBuffer f = modify (modifyRawbuf f)

queryAndModify :: (forall syntax. BufferImpl syntax -> (BufferImpl syntax,x)) -> BufferM x
queryAndModify f = getsAndModify (queryAndModifyRawbuf f)

-- | @addOverlayB s e sty@ overlays the style @sty@ between points @s@ and @e@
addOverlayB :: Point -> Point -> Style -> BufferM ()
addOverlayB s e sty = modifyBuffer $ addOverlayBI s e sty

-- | Execute a @BufferM@ value on a given buffer and window.  The new state of
-- the buffer is returned alongside the result of the computation.
runBuffer :: Window -> FBuffer -> BufferM a -> (a, FBuffer)
runBuffer w b f = let (a, b0, updates) = runRWS (fromBufferM f) w b
                in (a, modifier pendingUpdatesA (++ updates) b0)

-- | Execute a @BufferM@ value on a given buffer, using a dummy window.  The new state of
-- the buffer is returned alongside the result of the computation.
runBufferDummyWindow :: FBuffer -> BufferM a -> (a, FBuffer)
runBufferDummyWindow b = runBuffer (dummyWindow $ bkey b) b


-- Clear the undo list, so the changed "flag" is reset.
-- This has now been updated so that instead of clearing the undo list we
-- mark the point at which the file was saved.
clearUndosB :: BufferM ()
clearUndosB = modifyA undosA setSavedFilePointU

getfileB :: BufferM (Maybe FilePath)
getfileB = gets file

setfileB :: FilePath -> BufferM ()
setfileB f = setA fileA (Just f)

setnameB :: String -> BufferM ()
setnameB = setA nameA

keyB :: FBuffer -> BufferRef
keyB (FBuffer { bkey = u }) = u

isUnchangedB :: BufferM Bool
isUnchangedB = gets isUnchangedBuffer

isUnchangedBuffer :: FBuffer -> Bool
isUnchangedBuffer = isAtSavedFilePointU . undos


undoRedo :: (forall syntax. URList -> BufferImpl syntax -> (BufferImpl syntax, (URList, [Update])) ) -> BufferM ()
undoRedo f = do
  ur <- gets undos
  (ur', updates) <- queryAndModify (f ur)
  setA undosA ur'
  tell updates

undoB :: BufferM ()
undoB = undoRedo undoU

redoB :: BufferM ()
redoB = undoRedo redoU

emptyMode :: Mode syntax
emptyMode = Mode
  { 
   modeHL = ExtHL noHighlighter,
   modeKeymap = id,
   modeIndent = return ()
  }

-- | Create buffer named @nm@ with contents @s@
newB :: BufferRef -> String -> [Char] -> FBuffer
newB unique nm s =
    FBuffer { name   = nm
            , bkey   = unique
            , file   = Nothing          -- has name, not connected to a file
            , undos  = emptyU
            , rawbuf = newBI s
            , readOnly = False
            , bmode  = emptyMode
            , preferCol = Nothing
            , bufferDynamic = emptyDV
            , pendingUpdates = []
            , highlightSelection = False
            }

-- | Number of characters in the buffer
sizeB :: BufferM Int
sizeB = queryBuffer sizeBI

-- | Extract the current point
pointB :: BufferM Int
pointB = queryBuffer pointBI

-- | Return @n@ elems starting at @i@ of the buffer as a list
nelemsB :: Int -> Int -> BufferM [Char]
nelemsB n i = queryBuffer $ nelemsBI n i

-- | Return @n@ elems starting at @i@ of the buffer as a list
nelemsBH :: Int -> Int -> BufferM [(Char,Style)]
nelemsBH n i = queryBuffer $ nelemsBIH n i

styleRangesB :: Int -> Int -> BufferM [(Int,Style)]
styleRangesB n i = queryBuffer $ styleRangesBI n i

------------------------------------------------------------------------
-- Point based operations

-- | Move point in buffer to the given index
moveTo :: Int -> BufferM ()
moveTo x = do
  forgetPreferCol
  modifyBuffer $ moveToI x

------------------------------------------------------------------------

applyUpdate :: Update -> BufferM ()
applyUpdate update = do
  valid <- queryBuffer (isValidUpdate update)
  when valid $ do
       forgetPreferCol
       reversed <- queryBuffer (reverseUpdateI update)
       modifyBuffer (applyUpdateI update)
       modifyA undosA $ addChangeU $ AtomicChange $ reversed
       tell [update]
  -- otherwise, just ignore.

-- | Revert all the pending updates; don't touch the point.
revertPendingUpdatesB :: BufferM ()
revertPendingUpdatesB = do
  updates <- getA pendingUpdatesA
  modifyBuffer (flip (foldr (\u bi -> applyUpdateI (reverseUpdateI u bi) bi)) updates)

-- | Write an element into the buffer at the current point.
writeB :: Char -> BufferM ()
writeB c = do
  off <- pointB
  mapM_ applyUpdate [Delete off 1, Insert off [c]]

------------------------------------------------------------------------

-- | Insert the list at specified point, extending size of buffer
insertNAt :: [Char] -> Int -> BufferM ()
insertNAt cs pnt = applyUpdate (Insert pnt cs)


-- | Insert the list at current point, extending size of buffer
insertN :: [Char] -> BufferM ()
insertN cs = do
  pnt <- pointB
  applyUpdate (Insert pnt cs)

-- | Insert the char at current point, extending size of buffer
insertB :: Char -> BufferM ()
insertB = insertN . return

------------------------------------------------------------------------

-- | @deleteNAt n p@ deletes @n@ characters forwards from position @p@
deleteNAt :: Int -> Int -> BufferM ()
deleteNAt n pos = applyUpdate (Delete pos n)

------------------------------------------------------------------------
-- Line based editing

-- | Return the current line number
curLn :: BufferM Int
curLn = queryBuffer curLnI

-- | Go to line number @n@. @n@ is indexed from 1. Returns the
-- actual line we went to (which may be not be the requested line,
-- if it was out of range)
gotoLn :: Int -> BufferM Int
gotoLn x = do moveTo 0
              (1 +) <$> gotoLnFrom (x - 1)

---------------------------------------------------------------------

-- | Return index of next (or previous) string in buffer that matches argument
searchB :: Direction -> [Char] -> BufferM (Maybe Int)
searchB dir s = queryBuffer (searchBI dir s)

setMode0 :: forall syntax. Mode syntax -> FBuffer -> FBuffer
setMode0 m (FBuffer f1 f2 f3 f4 rb f6 f7 f8 f9 f10 f11) =
    (FBuffer f1 f2 f3 f4 (setSyntaxBI (modeHL m) rb) m f7 f8 f9 f10 f11)

-- | Set the mode
setMode :: Mode syntax -> BufferM ()
setMode m = do
  modify (setMode0 m)

withMode0 :: (forall syntax. Mode syntax -> a) -> FBuffer -> a
withMode0 f (FBuffer f1 f2 f3 f4 rb m f7 f8 f9 f10 f11) =
    f m 


withModeB :: (forall syntax. Mode syntax -> a) -> BufferM a
withModeB f = gets (withMode0 f)
           
withSyntax0 :: (forall syntax. Mode syntax -> syntax -> a) -> FBuffer -> a
withSyntax0 f (FBuffer f1 f2 f3 f4 rb m f7 f8 f9 f10 f11) =
    f m (getAst rb)
           

-- | Return indices of next string in buffer matched by regex
regexB :: Regex -> BufferM (Maybe (Int,Int))
regexB = queryBuffer . regexBI

---------------------------------------------------------------------

-- | Set a mark in this buffer
setMarkPointB :: Mark -> Int -> BufferM ()
setMarkPointB m pos = modifyBuffer $ setMarkPointBI m pos

getMarkPointB :: Mark -> BufferM Int
getMarkPointB = queryBuffer . getMarkPointBI

unsetMarkB :: BufferM ()
unsetMarkB = modifyBuffer unsetMarkBI

setVisibleSelection :: Bool -> BufferM ()
setVisibleSelection = setA highlightSelectionA

getMarkB :: Maybe String -> BufferM Mark
getMarkB m = queryAndModify (getMarkBI m)

getSelectionMarkB :: BufferM Mark
getSelectionMarkB = queryBuffer getSelectionMarkBI

-- | Returns the current difference in the selection point
-- and the current point. This will be negative if the point
-- ABOVE the selection point.
-- This can be therefore used to test which is above or below.
-- eg (do offset <- pointSelectionPointDiffB
--        if offset < 0
--           then point is above selection mark
--           else point is at below the selection mark.
pointSelectionPointDiffB :: BufferM Int
pointSelectionPointDiffB =
  do m <- getMarkPointB =<< getSelectionMarkB
     p <- pointB
     return (p - m)



-- | Move point by the given offset.
-- A negative offset moves backwards a positive one forward.
moveN :: Int -> BufferM ()
moveN n = do
  p <- pointB
  nextPoint <- queryBuffer (findNextChar n p)
  moveTo nextPoint

-- | Move point -1
leftB :: BufferM ()
leftB = leftN 1

-- | Move cursor -n
leftN :: Int -> BufferM ()
leftN n = moveN (-n)

-- | Move cursor +1
rightB :: BufferM ()
rightB = rightN 1

-- | Move cursor +n
rightN :: Int -> BufferM ()
rightN = moveN

-- ---------------------------------------------------------------------
-- Line based movement and friends

setPrefCol :: Maybe Int -> BufferM ()
setPrefCol = setA preferColA

-- | Move point down by @n@ lines. @n@ can be negative.
-- Returns the actual difference in lines which we moved which
-- may be negative if the requested line difference is negative.
lineMoveRel :: Int -> BufferM Int
lineMoveRel n = do
  prefCol <- getA preferColA
  targetCol <- case prefCol of
    Nothing -> offsetFromSol
    Just x -> return x
  ofs <- gotoLnFrom n
  gotoLnFrom 0 -- make sure we are at the start of line.
  solPnt <- pointB
  chrs <- nelemsB targetCol solPnt
  moveTo $ solPnt + maybe targetCol id (elemIndex '\n' chrs)
  --logPutStrLn $ "lineMoveRel: targetCol = " ++ show targetCol
  setPrefCol (Just targetCol)
  return ofs

forgetPreferCol :: BufferM ()
forgetPreferCol = setPrefCol Nothing

savingPrefCol :: BufferM a -> BufferM a
savingPrefCol f = do
  pc <- gets preferCol
  result <- f
  setPrefCol pc
  return result

-- | Move point up one line
lineUp :: BufferM ()
lineUp = lineMoveRel (-1) >> return ()

-- | Move point down one line
lineDown :: BufferM ()
lineDown = lineMoveRel 1 >> return ()

-- | Return the contents of the buffer as a list
elemsB :: BufferM [Char]
elemsB = do n <- sizeB
            nelemsB n 0

-- | Read the character at the current point
readB :: BufferM Char
readB = pointB >>= readAtB

-- | Read the character at the given index
-- This is an unsafe operation: character NUL is returned when out of bounds
readAtB :: Int -> BufferM Char
readAtB i = do
    s <- nelemsB 1 i
    return $ case s of
               [c] -> c
               _ -> '\0'

-- | Delete @n@ characters forward from the current point
deleteN :: Int -> BufferM ()
deleteN n = pointB >>= deleteNAt n

------------------------------------------------------------------------

-- | Offset from start of line
offsetFromSol :: BufferM Int
offsetFromSol = queryBuffer offsetFromSolBI

-- charsFromSol :: BufferM [String]
-- charsFromSol = do
  

-- | Go to line indexed from current point
-- Returns the actual moved difference which of course
-- may be negative if the requested difference was negative.
gotoLnFrom :: Int -> BufferM Int
gotoLnFrom x = queryAndModify $ gotoLnRelI x

bufferDynamicValueA :: Initializable a => Accessor FBuffer a
bufferDynamicValueA = dynamicValueA .> bufferDynamicA

getDynamicB :: Initializable a => BufferM a
getDynamicB = getA bufferDynamicValueA

-- | Insert a value into the extensible state, keyed by its type
setDynamicB :: Initializable a => a -> BufferM ()
setDynamicB = setA bufferDynamicValueA


-- | perform a @BufferM a@, and return to the current point. (by using a mark)
savingExcursionB :: BufferM a -> BufferM a
savingExcursionB f = do
    m <- getMarkB Nothing
    res <- f
    moveTo =<< getMarkPointB m
    return res

-- | perform an @BufferM a@, and return to the current point
savingPointB :: BufferM a -> BufferM a
savingPointB f = savingPrefCol $ do
  p <- pointB
  res <- f
  moveTo p
  return res

-------------
-- Window

askWindow :: (Window -> a) -> BufferM a
askWindow = asks
