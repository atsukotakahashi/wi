-- Copyright (c) Jean-Philippe Bernardy 2007.
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

module Yi.Keymap where

import Prelude hiding (error)
import Yi.UI
import qualified Yi.Editor as Editor
import Yi.Editor (EditorM, Editor, getBuffer)
import Yi.Debug
import qualified Data.Map as M
import Yi.Kernel
import Control.Monad.Reader
import Data.Typeable
import Data.IORef
import Data.Unique
import Control.Exception
import Control.Concurrent
import Control.Concurrent.MVar
import Yi.Buffer
import qualified Yi.Interact as I
import Yi.Monad
import Control.Monad.Writer

type Action = YiM ()

type Interact ev a = I.Interact ev (Writer [Action]) a

type Keymap = Interact Event ()

type KeymapMod = Keymap -> Keymap


data BufferKeymap = BufferKeymap 
    { bufferInput  :: !(Chan Event)      -- ^ input stream
    , bufferThread :: !(Maybe ThreadId)  -- ^ Id of the thread running the buffer's keymap. 
    , bufferKeymap :: !(IORef KeymapMod) -- ^ Buffer's local keymap modification
    , bufferKeymapRestartable :: !(MVar ()) -- ^ Put () in this MVar to mark the buffer ready to restart.
                                            -- FIXME: the bufferKeymap should really be an MVar, and that can be used to sync.
    -- In general , this is way more complicated than it should
    -- be. Just killing the thread and restarting another one looks
    -- like a better approach. 
    }

data Yi = Yi {yiEditor :: IORef Editor,
              yiUi :: UI,
              threads       :: IORef [ThreadId],                 -- ^ all our threads
              input         :: Chan Event,                 -- ^ input stream
              output        :: Chan Action,                -- ^ output stream
              defaultKeymap :: IORef Keymap,
              bufferKeymaps :: IORef (M.Map Unique BufferKeymap),
              -- FIXME: there is a latent bug here: the bufferkeymaps
              -- can be modified concurrently by the dispatcher thread
              -- and the worker thread.

              yiKernel  :: Kernel,
              editorModules :: IORef [String] -- ^ modules requested by user: (e.g. ["YiConfig", "Yi.Dired"])
             }

-- | The type of user-bindable functions
type YiM = ReaderT Yi IO

-----------------------
-- Keymap basics

runKeymap :: Interact ev () -> [ev] -> [Action]
runKeymap p evs = snd $ runWriter (I.runProcess p evs)

write :: Action -> Interact ev ()
write x = I.write (tell [x])


-----------------------
-- Keymap thread handling


setBufferKeymap :: FBuffer -> KeymapMod -> YiM ()
setBufferKeymap b km = do 
  bkm <- getBufferKeymap b
  lift $ writeIORef (bufferKeymap bkm) km
  restartBufferThread b
  lift $ logPutStrLn $ "Changed keymap for buffer " ++ show b
 
restartBufferThread :: FBuffer -> YiM ()
restartBufferThread b = do
  bkm <- getBufferKeymap b
  lift $ do logPutStrLn $ "Waiting for buffer thread to start: " ++ show b
            takeMVar (bufferKeymapRestartable bkm) 
            maybe (return ()) (flip throwDynTo "Keymap change") (bufferThread bkm)
            logPutStrLn $ "Restart signal sent: " ++ show b
            
deleteBufferKeymap :: FBuffer -> YiM ()
deleteBufferKeymap b = do
  bkm <- getBufferKeymap b
  lift $ do logPutStrLn $ "Waiting for buffer thread to start: " ++ show b
            takeMVar (bufferKeymapRestartable bkm) 
            maybe (return ()) killThread (bufferThread bkm)
  modifyRef bufferKeymaps (M.delete (keyB b))

startBufferKeymap :: FBuffer -> YiM BufferKeymap
startBufferKeymap b = do
  lift $ logPutStrLn $ "Starting buffer keymap: " ++ show b
  yi <- ask
  bkm <- lift $ 
         do r <- newEmptyMVar
            ch <- newChan
            km <- newIORef id
            let bkm = BufferKeymap { bufferInput = ch
                                   , bufferThread = Nothing
                                   , bufferKeymap = km
                                   , bufferKeymapRestartable = r
                                   }
            t <- forkIO $ bufferEventLoop yi b bkm
            return bkm {bufferThread = Just t}
  modifyRef bufferKeymaps (M.insert (keyB b) bkm)
  return bkm

getBufferKeymap :: FBuffer -> YiM BufferKeymap
getBufferKeymap b = do
  kms <- readRef bufferKeymaps
  case M.lookup (keyB b) kms of
    Just bkm -> return bkm 
    Nothing -> startBufferKeymap b
                           
bufferEventLoop :: Yi -> FBuffer -> BufferKeymap -> IO ()
bufferEventLoop yi buf b = eventLoop 
  where
    handler exception = logPutStrLn $ "Buffer event loop crashed with: " ++ (show exception)

    run bkm = do
      -- logStream ("Event for " ++ show b) (bufferInput b)
      logPutStrLn $ "Starting keymap thread for " ++ show buf
      tryPutMVar (bufferKeymapRestartable b) ()
      writeList2Chan (output yi) . bkm =<< getChanContents (bufferInput b)
      takeMVar (bufferKeymapRestartable b)
      logPutStrLn "Keymap execution ended"

    -- | The buffer's main loop. Read key strokes from the ui and interpret
    -- them using the current key map. Keys are bound to core actions.
    eventLoop :: IO ()
    eventLoop = do
      repeatM_ $ do -- get the new version of the keymap every time we need to start it.
                    defaultKm <- readIORef (defaultKeymap yi)
                    modKm <- readIORef (bufferKeymap b)
                    handle handler (run $ runKeymap $ I.forever (modKm defaultKm))

dispatch :: Event -> YiM ()
dispatch ev = do b <- withEditor getBuffer
                 bkm <- getBufferKeymap b
                 lift $ writeChan (bufferInput bkm) ev


--------------------------------
-- Uninteresting glue code

with :: (yi -> a) -> (a -> IO b) -> ReaderT yi IO b
with f g = do
    yi <- ask
    lift $ g (f yi)

withKernel :: (Kernel -> IO a) -> YiM a
withKernel = with yiKernel 

modifyRef :: (b -> IORef a) -> (a -> a) -> ReaderT b IO ()
modifyRef f g = do
  b <- ask
  lift $ modifyIORef (f b) g

readRef :: (b -> IORef a) -> ReaderT b IO a
readRef f = do
  b <- ask
  lift $ readIORef (f b)

withUI' :: (UI -> IO a) -> YiM a
withUI' = with yiUi

withUI :: (UI -> EditorM a) -> YiM a
withUI f = do
  e <- ask
  withEditor $ f $ yiUi $ e 

withEditor :: EditorM a -> YiM a
withEditor f = do
  e <- ask
  lift $ runReaderT f (yiEditor e)

withGivenBuffer b f = withEditor (Editor.withGivenBuffer0 b f)
withBuffer f = withEditor (Editor.withBuffer0 f)
withWindow f = withEditor (Editor.withWindow0 f)
readEditor f = withEditor (Editor.readEditor f)

catchDynE :: Typeable exception => YiM a -> (exception -> YiM a) -> YiM a
catchDynE inner handler = ReaderT (\r -> catchDyn (runReaderT inner r) (\e -> runReaderT (handler e) r))

catchJustE :: (Exception -> Maybe b) -- ^ Predicate to select exceptions
           -> YiM a	-- ^ Computation to run
           -> (b -> YiM a) -- ^	Handler
           -> YiM a
catchJustE p c h = ReaderT (\r -> catchJust p (runReaderT c r) (\b -> runReaderT (h b) r))

handleJustE :: (Exception -> Maybe b) -> (b -> YiM a) -> YiM a -> YiM a
handleJustE p h c = catchJustE p c h

-- | Shut down all of our threads. Should free buffers etc.
shutdown :: YiM ()
shutdown = do ts <- readRef threads
              lift $ mapM_ killThread ts

