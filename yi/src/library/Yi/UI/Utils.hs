-- Copyright (C) 2008 JP Bernardy
-- | Utilities shared by various UIs
module Yi.UI.Utils where

import Prelude hiding (mapM)
import Yi.Buffer
import Yi.Window
import Control.Arrow (second)
import Control.Applicative
import Control.Lens
import Data.Function (on)
import Data.Monoid
import Data.Traversable (Traversable, mapM)
import Data.Foldable (maximumBy)
import Yi.Style
import Data.List (transpose)
import Yi.Syntax (Span(..))
import Data.List.Split (chunksOf)
import Yi.String (padLeft)
import Control.Monad.State (evalState,modify)
import Control.Monad.State.Class (gets)

indexedAnnotatedStreamB :: Point -> BufferM [(Point, Char)]
indexedAnnotatedStreamB p = do
    text <- indexedStreamB Forward p
    annots <- withSyntaxB modeGetAnnotations
    return $ spliceAnnots text (dropWhile (\s -> spanEnd s < p) (annots p))

applyHeights :: Traversable t => [Int] -> t Window -> t Window
applyHeights heights ws = evalState (mapM distribute ws) heights
    where 
      distribute win = if isMini win 
          then return win{height = 1}
          else (do h <- gets head
                   modify tail
                   return win{height = h})


spliceAnnots :: [(Point,Char)] -> [Span String] -> [(Point,Char)]
spliceAnnots text [] = text
spliceAnnots text (Span start x stop:anns) = l ++ zip (repeat start) x ++ spliceAnnots r anns
    where (l,rest) =  span ((start >) . fst) text
          (_,r) = span ((stop >) . fst) rest

-- | Turn a sequence of (from,style,to) strokes into a sequence
--   of picture points (from,style), taking special care to
--   ensure that the points are strictly increasing and introducing
--   padding segments where neccessary.
--   Precondition: Strokes are ordered and not overlapping.
strokePicture :: [Span (Endo a)] -> [(Point,a -> a)]
strokePicture [] = []
strokePicture wholeList@(Span leftMost _ _:_) = helper leftMost wholeList
    where helper :: Point -> [Span (Endo a)] -> [(Point,a -> a)]
          helper prev [] = [(prev,id)]
          helper prev (Span l f r:xs)
              | prev < l  = (prev, id) : (l,appEndo f) : helper r xs
              | otherwise = (l,appEndo f) : helper r xs

-- | Paint the given stroke-picture on top of an existing picture
paintStrokes :: (a -> a) -> a -> [(Point,a -> a)] -> [(Point,a)] -> [(Point,a)]
paintStrokes f0 _  [] lx = fmap (second f0)     lx
paintStrokes _  x0 lf [] = fmap (second ($ x0)) lf
paintStrokes f0 x0 lf@((pf,f):tf) lx@((px,x):tx) =
  case pf `compare` px of
    LT -> (pf, f  x0):paintStrokes f  x0 tf lx
    EQ -> (pf, f  x ):paintStrokes f  x  tf tx
    GT -> (px, f0 x ):paintStrokes f0 x  lf tx



paintPicture :: a -> [[Span (Endo a)]] -> [(Point,a)]
paintPicture a = foldr (paintStrokes id a . strokePicture) []

attributesPictureB :: UIStyle -> Maybe SearchExp -> Region -> [[Span StyleName]] -> BufferM [(Point,Attributes)]
attributesPictureB sty mexp region extraLayers =
  paintPicture (baseAttributes sty) <$>
    fmap (fmap (fmap ($ sty))) <$>
    (extraLayers ++) <$>
    strokesRangesB mexp region

attributesPictureAndSelB :: UIStyle -> Maybe SearchExp -> Region -> BufferM [(Point,Attributes)]
attributesPictureAndSelB sty mexp region = do
    selReg <- getSelectRegionB
    showSel <- use highlightSelectionA
    rectSel <- use rectangleSelectionA
    let styliseReg reg = Span (regionStart reg) selectedStyle (regionEnd reg)
        extraLayers | rectSel && showSel = (:[]) . fmap styliseReg <$> blockifyRegion selReg
                    | showSel            = return [[styliseReg selReg]]
                    | otherwise          = return []
    attributesPictureB sty mexp region =<< extraLayers


-- | Arrange a list of items in columns over maximum @maxNumberOfLines@ lines
arrangeItems :: [String] -> Int -> Int -> [String]
arrangeItems items maxWidth maxNumberOfLines = take maxNumberOfLines $ snd choice
    where choice = maximumBy (compare `on` fst) arrangements
          arrangements = fmap (arrangeItems' items maxWidth) (reverse [1..maxNumberOfLines])

-- | Arrange a list of items in columns over @numberOfLines@ lines.
arrangeItems' :: [String] -> Int -> Int -> (Int, [String])
arrangeItems' items maxWidth numberOfLines = (fittedItems,theLines)
    where columns = chunksOf numberOfLines items
          columnsWidth = fmap (maximum . fmap length) columns
          totalWidths = scanl (\x y -> 1 + x + y) 0 columnsWidth
          shownItems = scanl (+) 0 (fmap length columns)
          fittedItems = snd $ last $ takeWhile ((<= maxWidth) . fst) $ zip totalWidths shownItems
          theLines = fmap (unwords . zipWith padLeft columnsWidth) $ transpose columns
