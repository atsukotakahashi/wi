{-# LANGUAGE BangPatterns, ExistentialQuantification, RecursiveDo, ParallelListComp #-}

-- Copyright (c) 2007, 2008 Jean-Philippe Bernardy

-- | This module defines a user interface implemented using gtk2hs and cairo for text rendering.

module Yi.UI.Cairo (start) where

import Prelude (filter, map, round, length, take, FilePath, (/), subtract)
import Yi.Prelude 
import Yi.Accessor
import Yi.Buffer
import Yi.Buffer.HighLevel (setSelectionMarkPointB, getSelectRegionB)
import Yi.Buffer.Region
import qualified Yi.Editor as Editor
import Yi.Editor hiding (windows)
import Yi.Window
import Yi.Event
import Yi.Keymap
import Yi.Debug
import Yi.Monad
import qualified Yi.UI.Common as Common
import Yi.UI.Common (UIConfig (..))
import Yi.Style hiding (modeline)
import qualified Yi.WindowSet as WS

import Control.Applicative
import Control.Concurrent ( yield )
import Control.Monad (ap)
import Control.Monad.Reader (liftIO, when, MonadIO)
import Control.Monad.State (runState, State, gets, modify)

import Data.Function
import Data.Foldable
import Data.IORef
import Data.List (nub, findIndex)
import Data.Maybe
import Data.Traversable
import qualified Data.Map as M

import Graphics.UI.Gtk hiding ( Window, Event, Action, Point, Style )
import qualified Graphics.UI.Gtk as Gtk
import Yi.UI.Gtk.ProjectTree
import Yi.UI.Gtk.Utils
import Yi.UI.Utils

------------------------------------------------------------------------

data UI = UI { uiWindow :: Gtk.Window
             , uiBox :: VBox
             , uiCmdLine :: Label
             , windowCache :: IORef [WinInfo]
             , uiActionCh :: Action -> IO ()
             , uiConfig :: Common.UIConfig
             }

data WinInfo = WinInfo
    {
      coreWin     :: Window
    , changedWin  :: IORef (Window)
    , renderer    :: IORef (ConnectId DrawingArea)
    , winMotionSignal :: IORef (Maybe (ConnectId DrawingArea))
    , winLayout   :: PangoLayout
    , winMetrics  :: FontMetrics
    , textview    :: DrawingArea
    , modeline    :: Label
    , widget      :: Box            -- ^ Top-level widget for this window.
    }

instance Show WinInfo where
    show w = show (coreWin w)

mkUI :: UI -> Common.UI
mkUI ui = Common.UI
  {
   Common.main                  = main                  ui,
   Common.end                   = end,
   Common.suspend               = windowIconify (uiWindow ui),
   Common.refresh               = refresh               ui,
   Common.prepareAction         = prepareAction         ui,
   Common.reloadProject         = reloadProject         ui
  }

mkFontDesc :: Common.UIConfig -> IO FontDescription
mkFontDesc cfg = do
  f <- fontDescriptionNew
  fontDescriptionSetFamily f "Monospace"
  case  Common.configFontSize cfg of
    Just x -> fontDescriptionSetSize f (fromIntegral x)
    Nothing -> return ()
  return f

-- | Initialise the ui
start :: Common.UIBoot
start cfg ch outCh _ed = do
  unsafeInitGUIForThreadedRTS

  -- rest.
  win <- windowNew
  windowSetDefaultSize win 500 700
  --windowFullscreen win
  ico <- loadIcon "yi+lambda-fat.32.png"
  windowSetIcon win ico

  onKeyPress win (processEvent ch)

  paned <- hPanedNew

  vb <- vBoxNew False 1  -- Top-level vbox

  (projectTree, _projectStore) <- projectTreeNew outCh  
  modulesTree <- treeViewNew

  tabs <- notebookNew
  set tabs [notebookTabPos := PosBottom]
  panedAdd1 paned tabs

  scrlProject <- scrolledWindowNew Nothing Nothing
  scrolledWindowAddWithViewport scrlProject projectTree
  scrolledWindowSetPolicy scrlProject PolicyAutomatic PolicyAutomatic
  notebookAppendPage tabs scrlProject "Project"

  scrlModules <- scrolledWindowNew Nothing Nothing
  scrolledWindowAddWithViewport scrlModules modulesTree
  scrolledWindowSetPolicy scrlModules PolicyAutomatic PolicyAutomatic
  notebookAppendPage tabs scrlModules "Modules"

  vb' <- vBoxNew False 1
  panedAdd2 paned vb'

  set win [ containerChild := vb ]
  onDestroy win mainQuit

  cmd <- labelNew Nothing
  set cmd [ miscXalign := 0.01 ]
  widgetModifyFont cmd =<< Just <$> mkFontDesc cfg

  set vb [ containerChild := paned,
           containerChild := cmd,
           boxChildPacking cmd  := PackNatural ]

  -- use our magic threads thingy (http://haskell.org/gtk2hs/archives/2005/07/24/writing-multi-threaded-guis/)
  timeoutAddFull (yield >> return True) priorityDefaultIdle 50

  widgetShowAll win

  wc <- newIORef []
  let ui = UI win vb' cmd wc outCh cfg 

  return (mkUI ui)

main :: UI -> IO ()
main _ui =
    do logPutStrLn "GTK main loop running"
       mainGUI

instance Show Gtk.Event where
    show (Key _eventRelease _eventSent _eventTime _eventModifier' _eventWithCapsLock _eventWithNumLock
                  _eventWithScrollLock _eventKeyVal eventKeyName' eventKeyChar')
        = "<modifier>" ++ " " ++ show eventKeyName' ++ " " ++ show eventKeyChar'
    show _ = "Not a key event"

processEvent :: (Event -> IO ()) -> Gtk.Event -> IO Bool
processEvent ch ev = do
  -- logPutStrLn $ "Gtk.Event: " ++ show ev
  -- logPutStrLn $ "Event: " ++ show (gtkToYiEvent ev)
  case gtkToYiEvent ev of
    Nothing -> logPutStrLn $ "Event not translatable: " ++ show ev
    Just e -> ch e
  return True

gtkToYiEvent :: Gtk.Event -> Maybe Event
gtkToYiEvent (Key {eventKeyName = keyName, eventModifier = evModifier, eventKeyChar = char})
    = fmap (\k -> Event k $ (nub $ (if isShift then filter (/= MShift) else id) $ concatMap modif evModifier)) key'
      where (key',isShift) =
                case char of
                  Just c -> (Just $ KASCII c, True)
                  Nothing -> (M.lookup keyName keyTable, False)
            modif Control = [MCtrl]
            modif Alt = [MMeta]
            modif Shift = [MShift]
            modif _ = []
gtkToYiEvent _ = Nothing

-- | Map GTK long names to Keys
keyTable :: M.Map String Key
keyTable = M.fromList
    [("Down",       KDown)
    ,("Up",         KUp)
    ,("Left",       KLeft)
    ,("Right",      KRight)
    ,("Home",       KHome)
    ,("End",        KEnd)
    ,("BackSpace",  KBS)
    ,("Delete",     KDel)
    ,("Page_Up",    KPageUp)
    ,("Page_Down",  KPageDown)
    ,("Insert",     KIns)
    ,("Escape",     KEsc)
    ,("Return",     KEnter)
    ,("Tab",        KTab)
    ,("ISO_Left_Tab", KTab)
    ]

-- | Clean up and go home
end :: IO ()
end = mainQuit

-- | Synchronize the windows displayed by GTK with the status of windows in the Core.
syncWindows :: Editor -> UI -> [(Window, Bool)] -- ^ windows paired with their "isFocused" state.
            -> [WinInfo] -> IO [WinInfo]
syncWindows e ui (wfocused@(w,focused):ws) (c:cs)
    | winkey w == winkey (coreWin c) = do when focused (setFocus c)
                                          (:) <$> syncWin w c <*> syncWindows e ui ws cs
    | winkey w `elem` map (winkey . coreWin) cs = removeWindow ui c >> syncWindows e ui (wfocused:ws) cs
    | otherwise = do c' <- insertWindowBefore e ui w c
                     when focused (setFocus c')
                     return (c':) `ap` syncWindows e ui ws (c:cs)
syncWindows e ui ws [] = mapM (insertWindowAtEnd e ui) (map fst ws)
syncWindows _e ui [] cs = mapM_ (removeWindow ui) cs >> return []

syncWin :: Window -> WinInfo -> IO WinInfo
syncWin w wi = do
  logPutStrLn $ "Updated one: " ++ show w
  writeRef (changedWin wi) w
  return (wi {coreWin = w})

setFocus :: WinInfo -> IO ()
setFocus w = do
  logPutStrLn $ "gtk focusing " ++ show w
  hasFocus <- widgetIsFocus (textview w)
  when (not hasFocus) $ widgetGrabFocus (textview w)

removeWindow :: UI -> WinInfo -> IO ()
removeWindow i win = containerRemove (uiBox i) (widget win)

instance Show Click where
    show x = case x of
               SingleClick  -> "SingleClick "
               DoubleClick  -> "DoubleClick "
               TripleClick  -> "TripleClick "
               ReleaseClick -> "ReleaseClick"

handleClick :: UI -> WinInfo -> Gtk.Event -> IO Bool
handleClick ui w event = do
  -- logPutStrLn $ "Click: " ++ show (eventX e, eventY e, eventClick e)

  -- retrieve the clicked offset.
  (_,layoutIndex,_) <- layoutXYToIndex (winLayout w) (eventX event) (eventY event)
  win <- readRef (changedWin w)
  let p1 = tospnt win + fromIntegral layoutIndex

  -- maybe focus the window
  logPutStrLn $ "Clicked inside window: " ++ show w
  wCache <- readIORef (windowCache ui)
  let Just idx = findIndex (((==) `on` (winkey . coreWin)) w) wCache
      focusWindow = modifyWindows (WS.focusIndex idx)

  case (eventClick event, eventButton event) of
     (SingleClick, LeftButton) -> do
       writeRef (winMotionSignal w) =<< Just <$> onMotionNotify (textview w) False (handleMove ui w p1)

     _ -> do maybe (return ()) signalDisconnect =<< readRef (winMotionSignal w)
             writeRef (winMotionSignal w) Nothing
             


  let editorAction = do
        b <- gets $ (bkey . findBufferWith (bufkey $ coreWin w))
        case (eventClick event, eventButton event) of
          (SingleClick, LeftButton) -> do
              focusWindow
              withGivenBuffer0 b $ moveTo p1
          (SingleClick, _) -> focusWindow
          (ReleaseClick, MiddleButton) -> do
            txt <- getRegE
            withGivenBuffer0 b $ do
              pointB >>= setSelectionMarkPointB
              moveTo p1
              insertN txt

          _ -> return ()

  uiActionCh ui (makeAction editorAction)
  return True

handleMove :: UI -> WinInfo -> Point -> Gtk.Event -> IO Bool
handleMove ui w p0 event = do
  logPutStrLn $ "Motion: " ++ show (eventX event, eventY event)

  -- retrieve the clicked offset.
  (_,layoutIndex,_) <- layoutXYToIndex (winLayout w) (eventX event) (eventY event)
  win <- readRef (changedWin w)
  let p1 = tospnt win + fromIntegral layoutIndex


  let editorAction = do
        txt <- withBuffer0 $ do
           if p0 /= p1 
            then Just <$> do
              m <- getSelectionMarkB
              setMarkPointB m p0
              moveTo p1
              setVisibleSelection True
              readRegionB =<< getSelectRegionB
            else return Nothing
        maybe (return ()) setRegE txt

  uiActionCh ui (makeAction editorAction)
  -- drawWindowGetPointer (textview w) -- be ready for next message.
  return True



-- | Make A new window
newWindow :: UI -> Window -> FBuffer -> IO WinInfo
newWindow ui w b = mdo
    f <- mkFontDesc (uiConfig ui)

    ml <- labelNew Nothing
    widgetModifyFont ml (Just f)
    set ml [ miscXalign := 0.01 ] -- so the text is left-justified.

    v <- drawingAreaNew
    widgetModifyFont v (Just f)
    widgetAddEvents v [Button1MotionMask]

    box <- if isMini w
     then do
      widgetSetSizeRequest v (-1) 1

      prompt <- labelNew (Just $ name b)
      widgetModifyFont prompt (Just f)

      hb <- hBoxNew False 1
      set hb [ containerChild := prompt,
               containerChild := v,
               boxChildPacking prompt := PackNatural,
               boxChildPacking v := PackGrow]

      return (castToBox hb)
     else do
      vb <- vBoxNew False 1
      set vb [ containerChild := v,
               containerChild := ml,
               boxChildPacking ml := PackNatural]
      return (castToBox vb)
     
    sig <- newIORef =<< (v `onExpose` render ui b win)
    wRef <- newIORef w
    context <- widgetCreatePangoContext v
    layout <- layoutEmpty context
    layoutSetWrap layout WrapAnywhere
    language <- contextGetLanguage context
    metrics <- contextGetMetrics context f language
    layoutSetFontDescription layout (Just f)
    motionSig <- newIORef Nothing
    let win = WinInfo {
                     coreWin   = w
                   , winLayout = layout
                   , winMetrics = metrics
                   , winMotionSignal = motionSig
                   , textview  = v
                   , modeline  = ml
                   , widget    = box
                   , renderer  = sig
                   , changedWin = wRef
              }
    return win

insertWindowBefore :: Editor -> UI -> Window -> WinInfo -> IO WinInfo
insertWindowBefore e i w _c = insertWindow e i w

insertWindowAtEnd :: Editor -> UI -> Window -> IO WinInfo
insertWindowAtEnd e i w = insertWindow e i w

insertWindow :: Editor -> UI -> Window -> IO WinInfo
insertWindow e i win = do
  let buf = findBufferWith (bufkey win) e
  liftIO $ do w <- newWindow i win buf
              set (uiBox i) [containerChild := widget w,
                             boxChildPacking (widget w) := if isMini (coreWin w) then PackNatural else PackGrow]
              textview w `onButtonRelease` handleClick i w
              textview w `onButtonPress` handleClick i w
              widgetShowAll (widget w)
              return w

refresh :: UI -> Editor -> IO ()
refresh ui e = do
    let ws = Editor.windows e
    let takeEllipsis s = if length s > 132 then take 129 s ++ "..." else s
    set (uiCmdLine ui) [labelText := takeEllipsis (statusLine e)]

    cache <- readRef $ windowCache ui
    logPutStrLn $ "syncing: " ++ show ws
    logPutStrLn $ "with: " ++ show cache
    cache' <- syncWindows e ui (toList $ WS.withFocus $ ws) cache
    logPutStrLn $ "Gives: " ++ show cache'
    writeRef (windowCache ui) cache'
    forM_ cache' $ \w -> do
        let b = findBufferWith (bufkey (coreWin w)) e
        --when (not $ null $ pendingUpdates b) $ 
        do 
           sig <- readIORef (renderer w)
           signalDisconnect sig
           writeRef (renderer w) =<< (textview w `onExpose` render ui b w)
           widgetQueueDraw (textview w)

winEls :: BufferM Yi.Buffer.Size
winEls = savingPointB $ do
             w <- askWindow id
             moveTo (tospnt w)
             gotoLnFrom (height w)
             p <- pointB
             return (p ~- tospnt w)

render :: UI -> FBuffer -> WinInfo -> t -> IO Bool
render _ui b w _ev = do
  win <- readRef (changedWin w)
  drawWindow <- widgetGetDrawWindow $ textview w
  (width, height) <- widgetGetSize $ textview w
  let [width', height'] = map fromIntegral [width, height]
  let metrics = winMetrics w
      layout = winLayout w
      winh = round (height' / (ascent metrics + descent metrics))

  let ((point, text),_) = runBuffer win {height = winh} b $ do
                      numChars <- winEls      
                      (,) 
                       <$> pointB
                       <*> nelemsB' numChars (tospnt win) 
  layoutSetWidth layout (Just width')
  layoutSetText layout text

  (_,bos,_) <- layoutXYToIndex layout width' height' 
  let win' = win { bospnt = fromIntegral bos + tospnt win,
                   height = winh
                 }

  -- Scroll the window when the cursor goes out of it:
  logPutStrLn $ "prewin: " ++ show win'
  logPutStrLn $ "point: " ++ show point
  win''' <- if pointInWindow point win'
    then return win'
    else do
      logPutStrLn $ "out!"
      let win'' = showPoint b win'
          (text', _) = runBuffer win'' b $ do
                         numChars <- winEls
                         nelemsB' numChars (tospnt win'')
      layoutSetText layout text'
      (_,bos',_) <- layoutXYToIndex layout width' height'
      logPutStrLn $ "bos = " ++ show bos' ++ " + " ++ show (tospnt win'')
      return win'' { bospnt = fromIntegral bos' + tospnt win''} 

  writeRef (changedWin w) win'''
  logPutStrLn $ "updated: " ++ show win'''

  -- add color attributes.
  let ((strokes,selectReg,selVisible), _) = runBuffer win''' b $ (,,)
                       <$> strokesRangesB (tospnt win''') (bospnt win''')
                       <*> getSelectRegionB
                       <*> getA highlightSelectionA
                         
      regInWin = fmapRegion (subtract (tospnt win''')) (intersectRegion selectReg (winRegion win'''))
      styleToAttrs (l,attrs,r) = [mkAttr l r a | a <- attrs]
      mkAttr l r (Foreground col) = AttrForeground (fromPoint (l - tospnt win''')) (fromPoint (r - tospnt win''')) (mkCol col)
      mkAttr l r (Background col) = AttrBackground (fromPoint (l - tospnt win''')) (fromPoint (r - tospnt win''')) (mkCol col)
      allAttrs = (if selVisible 
                   then (AttrBackground (fromPoint (regionStart regInWin)) (fromPoint (regionEnd regInWin - 1))
                           (Color 50000 50000 maxBound) :)
                   else id)
                  (concatMap styleToAttrs (concat strokes))

  layoutSetAttributes layout allAttrs


  (PangoRectangle curx cury curw curh, _) <- layoutGetCursorPos layout (fromPoint (point - tospnt win'''))

  gc <- gcNew drawWindow
  drawLayout drawWindow gc 0 0 layout

  -- paint the cursor   
  drawLine drawWindow gc (round curx, round cury) (round $ curx + curw, round $ cury + curh) 
  return True

prepareAction :: UI -> IO (EditorM ())
prepareAction ui = do
    wins <- mapM (readRef . changedWin) =<< readRef (windowCache ui)
    logPutStrLn $ "new wins: " ++ show wins
    return $ modifyWindows (\ws -> fst $ runState (mapM distribute ws) wins)

reloadProject :: UI -> FilePath -> IO ()
reloadProject _ _ = return ()

distribute :: Window -> State [Window] Window
distribute _ = do
  h <- gets head
  modify tail
  return h


mkCol :: Yi.Style.Color -> Gtk.Color
mkCol Default = Color 0 0 0
mkCol Reverse = Color maxBound maxBound maxBound
mkCol (RGB x y z) = Color (fromIntegral x * 256)
                          (fromIntegral y * 256)
                          (fromIntegral z * 256)
