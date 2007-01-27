--
-- Copyright (c) 2007 Jean-Philippe Bernardy
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation; either version 2 of
-- the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
-- 02111-1307, USA.
--


-- | This module defines a user interface implemented using gtk.

module Yi.UI (

        -- * UI initialisation
        start, end, suspend, main,

        -- * Window manipulation
        newWindow, enlargeWindow, shrinkWindow, 
        doResizeAll, deleteWindow, deleteWindow',
        hasRoomForExtraWindow,

        -- * UI type, abstract.
        UI,

        module Yi.Event   -- UIs need to export the symbolic key names


  )   where

import Prelude hiding (error)

import Yi.Buffer
import Yi.Editor
import Yi.Window as Window
import Yi.Event
import Yi.Debug

import Control.Concurrent ( yield )
import Control.Concurrent.Chan

import Data.List
import Data.Maybe
import qualified Data.Map as M

import Graphics.UI.Gtk hiding ( Window, Event )          
import qualified Graphics.UI.Gtk as Gtk


------------------------------------------------------------------------

data UI = UI {
              uiWindow :: Gtk.Window
             ,uiBox :: VBox
             ,uiFont :: FontDescription
             ,uiCmdLine :: Label
             }
-- | how to initialise the ui
start :: IO UI
start = do
  initGUI -- FIXME: forward args to the real main. ??

  win <- windowNew

  ch <- newChan
  modifyEditor_ $ \e -> return $ e { input = ch }
  onKeyPress win (processEvent ch)

  vb <- vBoxNew False 1
  set win [ containerChild := vb ]
  onDestroy win mainQuit
                
  cmd <- labelNew Nothing
  set cmd [ miscXalign := 0.01 ]
  set vb [ containerChild := cmd, 
           boxChildPacking cmd := PackNatural, 
           boxChildPosition cmd := 10 ] 

  -- use our magic threads thingy (http://haskell.org/gtk2hs/archives/2005/07/24/writing-multi-threaded-guis/)
  timeoutAddFull (yield >> return True) priorityDefaultIdle 50

  f <- fontDescriptionNew
  fontDescriptionSetFamily f "Monospace"

  widgetShowAll win
  return $ UI win vb f cmd

main :: IO ()
main = do logPutStrLn "GTK main loop running"
          mainGUI


processEvent :: Chan Event -> Gtk.Event -> IO Bool
processEvent ch ev = do
  logPutStrLn $ "Event: " ++ show (gtkToYiEvent ev)
  writeChan ch (gtkToYiEvent ev)
  return True
            
gtkToYiEvent :: Gtk.Event -> Event
gtkToYiEvent (Key {eventKeyName = name, eventModifier = modifier, eventKeyChar = char})
    = Event k $ (nub $ (if isShift then filter (not . (== MShift)) else id) $ map modif modifier)
      where (k,isShift) = 
                case char of
                  Just c -> (KASCII c, True)
                  Nothing -> (M.findWithDefault (KASCII '\0') name keyTable, False)
                              -- FIXME: return a more sensible result when we can't translate the event.
            modif Control = MCtrl
            modif Alt = MMeta
            modif Shift = MShift
            modif Apple = MMeta
            modif Compose = MMeta
gtkToYiEvent _ = Event (KASCII '\0') [] -- FIXME: return a more sensible result when we can't translate the event.

addWindow :: UI -> Window -> IO ()
addWindow ui w = do
  set (uiBox ui) [containerChild := widget w, 
                  boxChildPosition (widget w) := 0]
  widgetModifyFont (textview w) (Just (uiFont ui))
  widgetShowAll (widget w)


-- | Clean up and go home
end :: UI -> IO ()
end _ = mainQuit

-- | Suspend the program
suspend :: IO ()
suspend = do 
  i <- readEditor ui
  windowIconify (uiWindow i) 


------------------------------------------------------------------------
-- | Window manipulation

-- | Create a new window onto this buffer.
--
newWindow :: FBuffer -> IO Window
newWindow b = modifyEditor $ \e -> do
    win  <- emptyWindow b (1,1) -- FIXME
    addWindow (ui e) win
    let e' = e { windows = M.fromList $ mkAssoc (win : M.elems (windows e)) }
    return (e', win)

-- ---------------------------------------------------------------------
-- | Grow the given window, and pick another to shrink
-- grow and shrink compliment each other, they could be refactored.
--
enlargeWindow :: Maybe Window -> IO ()
enlargeWindow _ = return () -- TODO

-- | shrink given window (just grow another)
shrinkWindow :: Maybe Window -> IO ()
shrinkWindow _ = return () -- TODO


--
-- | Delete a window. Note that the buffer that was connected to this
-- window is still open.
--
deleteWindow :: (Maybe Window) -> IO ()
deleteWindow Nothing    = return ()
deleteWindow (Just win) = modifyEditor_ $ \e -> deleteWindow' e win

-- internal, non-thread safe
deleteWindow' :: Editor -> Window -> IO Editor
deleteWindow' e win = do
  let i = ui e
  containerRemove (uiBox i) (widget win)
  return e

-- | Has the frame enough room for an extra window.
hasRoomForExtraWindow :: IO Bool
hasRoomForExtraWindow = return True

doResizeAll :: IO ()
doResizeAll = return ()

-- | Map GTK long names to Keys
keyTable :: M.Map String Key
keyTable = M.fromList 
    [("Down",       KDown) -- defns imported from Yi.Char
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
    ]

