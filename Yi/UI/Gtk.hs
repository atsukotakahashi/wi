{-# LANGUAGE BangPatterns, ExistentialQuantification #-}

-- Copyright (c) 2007, 2008 Jean-Philippe Bernardy

-- | This module defines a user interface implemented using gtk2hs.

module Yi.UI.Gtk (start) where

import Prelude (filter, map, round, length, take, FilePath)
import Yi.Prelude 
import Yi.Buffer
import Yi.Buffer.Implementation (inBounds)
import qualified Yi.Editor as Editor
import Yi.Editor hiding (windows)
import qualified Yi.Window as Window
import Yi.Window (Window)
import Yi.Event
import Yi.Keymap
import Yi.Monad
import qualified Yi.UI.Common as Common
import Yi.Config
import Yi.Style hiding (modeline)
import qualified Yi.WindowSet as WS
import Control.Arrow (second)
import Control.Applicative
import Control.Concurrent ( yield )
import Control.Monad (ap)
import Control.Monad.Reader (liftIO, when, MonadIO)
import Control.Monad.State (runState, State, gets, modify)

import Data.Foldable
import Data.IORef
import Data.List (drop, nub, findIndex, sort, zip)
import Data.Maybe
import Data.Monoid
import Data.Traversable
import Data.Unique
import qualified Data.Map as M

import Graphics.UI.Gtk hiding ( Window, Event, Action, Point, Style, Region )
import qualified Graphics.UI.Gtk as Gtk
import qualified Graphics.UI.Gtk.ModelView as MView
import Yi.UI.Gtk.ProjectTree
import Yi.UI.Gtk.Utils
import Yi.UI.Utils
import Shim.ProjectContent
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8

------------------------------------------------------------------------

data UI = UI { uiWindow :: Gtk.Window
             , uiBox :: VBox
             , uiCmdLine :: Label
             , uiBuffers :: IORef (M.Map BufferRef TextBuffer)
             , tagTable :: TextTagTable
             , windowCache :: IORef [WinInfo]
             , uiActionCh :: Action -> IO ()
             , uiConfig :: UIConfig
             , uiFilesStore   :: MView.TreeStore ProjectItem
             , uiModulesStore :: MView.TreeStore ProjectItem
             }

data WinInfo = WinInfo
    {
      winref      :: !Window.WindowRef     -- ^ The reference of the Yi window this GTK window represents.
    , wkey        :: !Unique
    , textview    :: TextView
    , modeline    :: Label
    , widget      :: Box            -- ^ Top-level widget for this window.
    , isMini      :: Bool
    }

instance Show WinInfo where
    show w = "W" ++ show (hashUnique $ wkey w) ++ " on " ++ show (winref w)

bufkey :: Editor -> WinInfo -> BufferRef
bufkey e w = Window.bufkey $ findWindowWith (winref w) e

mkUI :: UI -> Common.UI
mkUI ui = Common.dummyUI
  {
   Common.main                  = main ui,
   Common.end                   = postGUIAsync $ end,
   Common.suspend               = postGUIAsync $ windowIconify (uiWindow ui),
   Common.refresh               = postGUIAsync . refresh                 ui,
   Common.prepareAction         =                prepareAction           ui,
   Common.reloadProject         = postGUIAsync . reloadProject           ui
  }

mkFontDesc :: UIConfig -> IO FontDescription
mkFontDesc cfg = do
  f <- fontDescriptionNew
  fontDescriptionSetFamily f (maybe "Monospace" id (configFontName cfg))
  case  configFontSize cfg of
    Just x -> fontDescriptionSetSize f (fromIntegral x)
    Nothing -> return ()
  return f

-- | Initialise the ui
start :: UIBoot
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

  (filesTree,   filesStore) <- projectTreeNew (outCh . singleton)
  (modulesTree, modulesStore) <- projectTreeNew (outCh . singleton)

  tabs <- notebookNew
  set tabs [notebookTabPos := PosBottom]
  panedAdd1 paned tabs

  scrlProject <- scrolledWindowNew Nothing Nothing
  scrolledWindowAddWithViewport scrlProject filesTree
  scrolledWindowSetPolicy scrlProject PolicyAutomatic PolicyAutomatic
  notebookAppendPage tabs scrlProject "Files"

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
  widgetModifyFont cmd =<< Just <$> mkFontDesc (configUI cfg)

  set vb [ containerChild := paned,
           containerChild := cmd,
           boxChildPacking cmd  := PackNatural ]

  -- use our magic threads thingy (http://haskell.org/gtk2hs/archives/2005/07/24/writing-multi-threaded-guis/)
  timeoutAddFull (yield >> return True) priorityDefaultIdle 50

  widgetShowAll win

  bufs <- newIORef M.empty
  wc <- newIORef []
  tt <- textTagTableNew

  let ui = UI win vb' cmd bufs tt wc (outCh . singleton) (configUI cfg) filesStore modulesStore

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
    = fmap (\k -> Event k $ (nub $ sort $ (if isShift then filter (/= MShift) else id) $ concatMap modif evModifier)) key'
      where (key',isShift) =
                case char of
                  Just c -> (Just $ KASCII c, True)
                  Nothing -> (M.lookup keyName keyTable, False)
            modif Control = [MCtrl]
            modif Alt = [MMeta]
            modif Shift = [MShift]
            modif _ = [] -- Use underscore so we don't depend on the differences between gtk2hs versions
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
    | Window.wkey w == winref c = do when focused (setFocus c)
                                     return (c:) `ap` syncWindows e ui ws cs
    | Window.wkey w `elem` map winref cs = removeWindow ui c >> syncWindows e ui (wfocused:ws) cs
    | otherwise = do c' <- insertWindowBefore e ui w c
                     when focused (setFocus c')
                     return (c':) `ap` syncWindows e ui ws (c:cs)
syncWindows e ui ws [] = mapM (insertWindowAtEnd e ui) (map fst ws)
syncWindows _e ui [] cs = mapM_ (removeWindow ui) cs >> return []

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
  let tv = textview w
  let wx = round (eventX event)
  let wy = round (eventY event)
  (bx, by) <- textViewWindowToBufferCoords tv TextWindowText (wx,wy)
  iter <- textViewGetIterAtLocation tv bx by
  p1 <- Point <$> get iter textIterOffset

  -- maybe focus the window
  logPutStrLn $ "Clicked inside window: " ++ show w
  wCache <- readIORef (windowCache ui)
  let Just idx = findIndex ((wkey w ==) . wkey) wCache
      focusWindow = modifyWindows (WS.focusIndex idx)
  logPutStrLn $ "Will focus to index: " ++ show (findIndex ((wkey w ==) . wkey) wCache)

  let editorAction = do
        b <- gets $ \editor -> bkey $ findBufferWith (bufkey editor w) editor
        case (eventClick event, eventButton event) of
          (SingleClick, LeftButton) -> do
              focusWindow
              withGivenBuffer0 b $ do moveTo p1 -- as a side effect we forget the prefered column
                                      setVisibleSelection True
          (SingleClick, _) -> focusWindow
          (ReleaseClick, LeftButton) -> do
            p0 <- withGivenBuffer0 b $ pointB
            if p1 == p0
              then withGivenBuffer0 b $ setVisibleSelection False
              else do txt <- withGivenBuffer0 b $ do setMarkPointB staticSelMark p1
                                                     let [i,j] = sort [p1,p0]
                                                     nelemsB' (j~-i) i
                      setRegE txt
          (ReleaseClick, MiddleButton) -> do
            txt <- getRegE
            withGivenBuffer0 b $ do
              pointB >>= setSelectionMarkPointB
              moveTo p1
              insertN txt

          _ -> return ()

  uiActionCh ui (makeAction editorAction)
  return True


-- | Make A new window
newWindow :: Editor -> UI -> Bool -> Window -> IO WinInfo
newWindow editor ui mini win = do
    let buf = findBufferWith (Window.bufkey win) editor
    f <- mkFontDesc (uiConfig ui)

    ml <- labelNew Nothing
    widgetModifyFont ml (Just f)
    set ml [ miscXalign := 0.01 ] -- so the text is left-justified.

    v <- textViewNew
    textViewSetWrapMode v WrapChar
    widgetModifyFont v (Just f)

    -- Apply the window style attributes to the text view.
    let styAttr = window $ configStyle $ uiConfig ui
    case appEndo styAttr defaultAttributes of
            (Attributes _ c) -> do
                let toColor Default = Color 0xffff 0xffff 0xffff
                    toColor Reverse = Color 0 0 0
                    toColor (RGB r g b) = Color (fromIntegral r * 0xff) (fromIntegral g * 0xff) (fromIntegral b * 0xff)
                widgetModifyBase v StateNormal $ toColor c
            _ -> return ()
            {- Should be something like below. However, widgetModifyCursor is not in my version of
             - gtk2hs! -CROC
            Foreground c -> do
                let toColor Default = Color 0 0 0
                    toColor Reverse = Color 0xffff 0xffff 0xffff
                    toColor (RGB r g b) = Color (fromIntegral r * 0xff) (fromIntegral g * 0xff) (fromIntegral b * 0xff)
                widgetModifyCursor v StateNormal $ toColor c
            -}

    box <- if mini
     then do
      widgetSetSizeRequest v (-1) 1

      prompt <- labelNew (Just $ name buf)
      widgetModifyFont prompt (Just f)

      hb <- hBoxNew False 1
      set hb [ containerChild := prompt,
               containerChild := v,
               boxChildPacking prompt := PackNatural,
               boxChildPacking v := PackGrow]

      return (castToBox hb)
     else do
      scroll <- scrolledWindowNew Nothing Nothing
      set scroll [scrolledWindowPlacement := if configLeftSideScrollBar $ uiConfig $ ui then CornerTopRight else CornerTopLeft,
                  scrolledWindowVscrollbarPolicy := if configAutoHideScrollBar $ uiConfig $ ui then PolicyAlways else PolicyAutomatic,
                  scrolledWindowHscrollbarPolicy := PolicyAutomatic,
                  containerChild := v]

      vb <- vBoxNew False 1
      set vb [ containerChild := scroll,
               containerChild := ml,
               boxChildPacking ml := PackNatural]
      return (castToBox vb)

    gtkBuf <- getGtkBuffer ui buf

    textViewSetBuffer v gtkBuf

    k <- newUnique
    let gtkWin = WinInfo {
                     winref    = Window.wkey win
                   , wkey      = k
                   , textview  = v
                   , modeline  = ml
                   , widget    = box
                   , isMini    = mini
              }
    return gtkWin

insertWindowBefore :: Editor -> UI -> Window -> WinInfo -> IO WinInfo
insertWindowBefore e i w _c = insertWindow e i w

insertWindowAtEnd :: Editor -> UI -> Window -> IO WinInfo
insertWindowAtEnd e i w = insertWindow e i w

insertWindow :: Editor -> UI -> Window -> IO WinInfo
insertWindow e i win = do
  liftIO $ do w <- newWindow e i (Window.isMini win) win
              set (uiBox i) [containerChild := widget w,
                             boxChildPacking (widget w) := if isMini w then PackNatural else PackGrow]
              textview w `onButtonRelease` handleClick i w
              textview w `onButtonPress` handleClick i w
              set (textview w) [textViewWrapMode := if configLineWrap $ uiConfig $ i then WrapChar else WrapNone]
              widgetShowAll (widget w)
              return w

refresh :: UI -> Editor -> IO ()
refresh ui e = do
    let ws = Editor.windows e
    let takeEllipsis s = if length s > 132 then take 129 s ++ "..." else s
    set (uiCmdLine ui) [labelText := takeEllipsis (statusLine e)]
    cache <- readRef $ windowCache ui

    -- Update the GTK text buffers for all the updates that have occured in the backing Yi buffers
    -- since the last refresh.
    -- Iterate over all the buffers in the editor 
    forM_ (buffers e) $ \buf -> when (not $ null $ pendingUpdates $ buf) $ do
      -- Apply all pending updates.
      gtkBuf <- getGtkBuffer ui buf
      forM_ ([u | TextUpdate u <- pendingUpdates buf]) $ applyUpdate gtkBuf
      let size = runBufferDummyWindow buf sizeB
      forM_ ([mkSizeRegion s l | StyleUpdate s l <- pendingUpdates buf]) $ \r -> replaceTagsIn ui r buf gtkBuf
      -- Update all the tags in each region that is currently displayed.
      -- As multiple windows can be displaying the same buffer this is done for each window.
      forM_ ws $ \w -> when (Window.bufkey w == bkey buf) $ do  
          let p = fst $ runBuffer w buf pointB
          replaceTagsIn ui (mkRegion (max 0 (p-100)) (min (p+100) size)) buf gtkBuf
    logPutStrLn $ "syncing: " ++ show ws
    logPutStrLn $ "with: " ++ show cache
    cache' <- syncWindows e ui (toList $ WS.withFocus $ ws) cache
    logPutStrLn $ "Gives: " ++ show cache'
    writeRef (windowCache ui) cache'
    forM_ cache' $ \w ->
        do let buf = findBufferWith (bufkey e w) e
               win = findWindowWith (winref w) e
           gtkBuf <- getGtkBuffer ui buf

           let (Point p0) = fst $ runBuffer win buf pointB
           let (Point p1) = fst $ runBuffer win buf (getMarkPointB staticSelMark)
           let (showSel) = fst $ runBuffer win buf (getA highlightSelectionA)
           i <- textBufferGetIterAtOffset gtkBuf p0
           if showSel 
              then do
                 i' <- textBufferGetIterAtOffset gtkBuf p1
                 textBufferSelectRange gtkBuf i i'
              else do
                 textBufferPlaceCursor gtkBuf i
           insertMark <- textBufferGetInsert gtkBuf
           textViewScrollMarkOnscreen (textview w) insertMark
           let txt = runBufferDummyWindow buf getModeLine
           set (modeline w) [labelText := txt]

replaceTagsIn :: UI -> Region -> FBuffer -> TextBuffer -> IO ()
replaceTagsIn ui r buf gtkBuf = do
  i <- textBufferGetIterAtOffset gtkBuf (fromPoint $ regionStart r)
  i' <- textBufferGetIterAtOffset gtkBuf (fromPoint $ regionEnd r)
  let (sizeBuf, styleSpans) = 
         runBufferDummyWindow buf $ (,) <$> sizeB <*> (strokesRangesB Nothing r)
      actualStrokes :: [[(Point,Style,Point)]]
      actualStrokes = (map (map (toActualStroke (configStyle $ uiConfig ui))) styleSpans)
      picture :: [(Point, Attributes)]
      picture = paintPicture defaultAttributes actualStrokes
      styleRanges :: [(Point, Attributes)]
--      styleRanges = map (second appStyle) picture
      styleRanges = picture
  textBufferRemoveAllTags gtkBuf i i'
  forM_ (zip styleRanges (map fst (drop 1 styleRanges) ++ [sizeBuf]) ) $ \((l,s),r) -> do
    f <- textBufferGetIterAtOffset gtkBuf (fromPoint l)
    t <- textBufferGetIterAtOffset gtkBuf (fromPoint r)
    tags <- styleToTag ui s
    forM tags $ \tag -> textBufferApplyTag gtkBuf tag f t

applyUpdate :: TextBuffer -> Update -> IO ()
applyUpdate buf (Insert (Point p) _ s) = do
  i <- textBufferGetIterAtOffset buf p
  textBufferInsert buf i (LazyUTF8.toString s)

applyUpdate buf (Delete p _ s) = do
  i0 <- textBufferGetIterAtOffset buf (fromPoint p)
  i1 <- textBufferGetIterAtOffset buf (fromPoint p + length (LazyUTF8.toString s))
  textBufferDelete buf i0 i1

styleToTag :: UI -> Attributes -> IO [TextTag]
styleToTag ui a = case a of
    (Attributes f b) -> sequence [tagOf textTagForeground f, tagOf textTagBackground b]

 where tagOf attr col = do
         let fgText = colorToText col
         mtag <- textTagTableLookup (tagTable ui) fgText
         case mtag of
           Just x -> return x
           Nothing -> do x <- textTagNew (Just fgText)
                         set x [attr := fgText]
                         textTagTableAdd (tagTable ui) x
                         return x

prepareAction :: UI -> IO (EditorM ())
prepareAction ui = do
    -- compute the heights of all windows (in number of lines)
    gtkWins <- readRef (windowCache ui)
    heights <- forM gtkWins $ \w -> do
                     let gtkWin = textview w
                     d <- widgetGetDrawWindow gtkWin
                     (_w,h) <- drawableGetSize d
                     (_,y0) <- textViewWindowToBufferCoords gtkWin TextWindowText (0,0)
                     (i0,_) <- textViewGetLineAtY gtkWin y0
                     l0 <- get i0 textIterLine
                     (_,y1) <- textViewWindowToBufferCoords gtkWin TextWindowText (0,h)
                     (i1,_) <- textViewGetLineAtY gtkWin y1
                     l1 <- get i1 textIterLine
                     return (l1 - l0)
    -- updates the heights of the windows
    return $ 
      modifyWindows (\ws -> if WS.size ws == length heights 
                              then fst $ runState (mapM distribute ws) heights
                              else trace ("INFO: updates the heights of the windows: unmatching lengths") ws)

reloadProject :: UI -> FilePath -> IO ()
reloadProject ui fpath = do
  (files,mods) <- loadProject fpath
  loadProjectTree (uiFilesStore   ui) files
  loadProjectTree (uiModulesStore ui) mods

distribute :: Window -> State [Int] Window
distribute win = do
  h <- gets hd
  modify tail
  return win {Window.height = h}
      where hd (h:_) = h
            hd [] = error "distribute: non-matching list lengths"

getGtkBuffer :: UI -> FBuffer -> IO TextBuffer
getGtkBuffer ui b = do
    let bufsRef = uiBuffers ui
    bufs <- readRef bufsRef
    gtkBuf <- case M.lookup (bkey b) bufs of
      Just gtkBuf -> return gtkBuf
      Nothing -> newGtkBuffer ui b
    modifyRef bufsRef (M.insert (bkey b) gtkBuf)
    return gtkBuf

-- FIXME: when a buffer is deleted its GTK counterpart should be too.
newGtkBuffer :: UI -> FBuffer -> IO TextBuffer
newGtkBuffer ui b = do
  buf <- textBufferNew (Just (tagTable ui))
  let (txt,sz) = runBufferDummyWindow b $ do
                      revertPendingUpdatesB
                      (,) <$> elemsB <*> sizeB
  textBufferSetText buf txt
  replaceTagsIn ui (mkRegion 0 sz) b buf
  return buf

