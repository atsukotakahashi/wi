{-# LANGUAGE PatternSignatures #-}

-- Copyright (c) Tuomo Valkonen 2004.
-- Copyright (c) Don Stewart 2004-5. http://www.cse.unsw.edu.au/~dons

--
-- | The core actions of yi. This module is the link between the editor
-- and the UI. Key bindings, and libraries should manipulate Yi through
-- the interface defined here.

module Yi.Core (
                module Yi.Dynamic,
        -- * Keymap
        module Yi.Keymap,

        -- * Construction and destruction
        StartConfig    ( .. ), -- Must be passed as the first argument to 'startE'
        startE,         -- :: StartConfig -> Kernel -> Maybe Editor -> [YiM ()] -> IO ()
        quitE,          -- :: YiM ()

#ifdef DYNAMIC
        reconfigE,
        loadE,
        unloadE,
#endif
        reloadE,        -- :: YiM ()
        getNamesInScopeE,
        execE,

        refreshE,       -- :: YiM ()
        suspendE,       -- :: YiM ()

        -- * Global editor actions
        msgE,           -- :: String -> YiM ()
        errorE,         -- :: String -> YiM ()
        msgClrE,        -- :: YiM ()
        setWindowFillE, -- :: Char -> YiM ()
        setWindowStyleE,-- :: UIStyle -> YiM ()

        -- * Window manipulation
        closeE,         -- :: YiM ()

        -- * Buffer only stuff
        newBufferE,     -- :: String -> String -> YiM ()
        listBuffersE,   -- :: YiM ()
        closeBufferE,   -- :: String -> YiM ()
        getBufferWithName,

        -- * Buffer/Window
        closeBufferAndWindowE,
        switchToBufferE,
        switchToBufferOtherWindowE,
        switchToBufferWithNameE,
        nextBufW,       -- :: YiM ()
        prevBufW,       -- :: YiM ()

        -- * Basic registers
        setRegE,        -- :: String -> YiM ()
        getRegE,        -- :: EditorM String

        -- * Dynamically extensible state
        getDynamic,
        setDynamic,

        -- * Interacting with external commands
        pipeE,                   -- :: String -> String -> EditorM String

        -- * Misc
        changeKeymapE,
        runAction
   ) where

import Prelude hiding (error, sequence_, mapM_, elem, concat, all)

import Yi.Debug
import Yi.Undo
import Yi.Buffer
import Yi.Window
import Yi.Dynamic
import Yi.String
import Yi.Process           ( popen )
import Yi.Editor
import Yi.CoreUI
import Yi.Kernel
import Yi.Event (eventToChar, Event)
import Yi.Keymap
import qualified Yi.Interact as I
import Yi.Monad
import Yi.Accessor
import qualified Yi.WindowSet as WS
import qualified Yi.Editor as Editor
import qualified Yi.Style as Style
import qualified Yi.UI.Common as UI
import Yi.UI.Common as UI (UI)

import Data.Maybe
import qualified Data.Map as M
import Data.List
  ( notElem
  , delete
  )
import Data.IORef
import Data.Foldable

import System.FilePath

import Control.Monad (when, forever)
import Control.Monad.Reader (runReaderT, ask)
import Control.Monad.Trans
import Control.Monad.State (gets, modify)
import Control.Monad.Error ()
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Chan

#ifdef DYNAMIC

import qualified GHC
import qualified DynFlags
import qualified SrcLoc
import qualified ErrUtils
import Outputable

#endif

-- | Make an action suitable for an interactive run.
-- UI will be refreshed.
interactive :: Action -> YiM ()
interactive action = do
  logPutStrLn ">>>>>>> interactively"
  prepAction <- withUI UI.prepareAction
  withEditor $ do prepAction
                  modifyAllA buffersA undosA (addUR InteractivePoint)
  runAction action
  refreshE
  logPutStrLn "<<<<<<<"
  return ()

nilKeymap :: Keymap
nilKeymap = do c <- I.anyEvent
               write $ case eventToChar c of
                         'q' -> quitE
                         'r' -> reconfigE
                         'h' -> (configHelp >> return ())
                         _ -> errorE $ "Keymap not defined, type 'r' to reload config, 'q' to quit, 'h' for help."
    where configHelp = newBufferE "*configuration help*" $ unlines $
                         ["To get a standard reasonable keymap, you can run yi with either --as=vim or --as=emacs.",
                          "You can also create your own ~/.yi/YiConfig.hs file,",
                          "see http://haskell.org/haskellwiki/Yi#How_to_Configure_Yi for help on how to do that."]


data StartConfig = StartConfig { startFrontEnd   :: UI.UIBoot
                               , startConfigFile :: FilePath
                               }

-- ---------------------------------------------------------------------
-- | Start up the editor, setting any state with the user preferences
-- and file names passed in, and turning on the UI
--
startE :: StartConfig -> Kernel -> Maybe Editor -> [YiM ()] -> IO ()
startE startConfig kernel st commandLineActions = do
    let yiConfigFile   = startConfigFile startConfig
        uiStart        = startFrontEnd startConfig

    logPutStrLn "Starting Core"

    -- restore the old state
    let initEditor = maybe emptyEditor id st
    newSt <- newIORef initEditor
    -- Setting up the 1st window is a bit tricky because most functions assume there exists a "current window"
    inCh <- newChan
    outCh :: Chan Action <- newChan
    ui <- uiStart inCh outCh initEditor makeAction
    startKm <- newIORef nilKeymap
    startModules <- newIORef ["Yi.Yi"] -- this module re-exports all useful stuff, so we want it loaded at all times.
    startThreads <- newIORef []
    keymaps <- newIORef M.empty
    let yi = Yi newSt ui startThreads inCh outCh startKm keymaps kernel startModules
        runYi f = runReaderT f yi

    runYi $ do

      newBufferE "*messages*" "" >> return ()

#ifdef DYNAMIC
      withKernel $ \k -> do
        dflags <- getSessionDynFlags k
        setSessionDynFlags k dflags { GHC.log_action = ghcErrorReporter yi }
      -- run user configuration
      loadE yiConfigFile -- "YiConfig"
      runConfig
#endif

      when (isNothing st) $ do -- process options if booting for the first time
        sequence_ commandLineActions

    logPutStrLn "Starting event handler"
    let
        handler e = runYi $ errorE (show e)
        -- | The editor's input main loop.
        -- Read key strokes from the ui and dispatches them to the buffer with focus.
        eventLoop :: IO ()
        eventLoop = do
            let run = mapM_ (\ev -> runYi (dispatch ev)) =<< getChanContents inCh
            forever $ (handle handler run >> logPutStrLn "Dispatching loop ended")


        -- | The editor's output main loop.
        execLoop :: IO ()
        execLoop = do
            runYi refreshE
            let loop = sequence_ . map runYi . map interactive =<< getChanContents outCh
            forever $ (handle handler loop >> logPutStrLn "Execing loop ended")

    t1 <- forkIO eventLoop
    t2 <- forkIO execLoop
    runYi $ modifiesRef threads (\ts -> t1 : t2 : ts)

    UI.main ui -- transfer control to UI: GTK must run in the main thread, or else it's not happy.

postActions :: [Action] -> YiM ()
postActions actions = do yi <- ask; lift $ writeList2Chan (output yi) actions

-- | Process an event by advancing the current keymap automaton an
-- execing the generated actions
dispatch :: Event -> YiM ()
dispatch ev =
    do yi <- ask
       b <- withEditor getBuffer
       bkm <- getBufferKeymap b
       defKm <- readRef (defaultKeymap yi)
       let p0 = bufferKeymapProcess bkm
           freshP = I.mkAutomaton $ bufferKeymap bkm $ defKm
           p = case p0 of
                 I.End -> freshP
                 I.Fail -> freshP -- TODO: output error message about unhandled input
                 _ -> p0
           (actions, p') = I.processOneEvent p ev
           possibilities = I.possibleActions p'
           ambiguous = not (null possibilities) && all isJust possibilities
       logPutStrLn $ "Processing: " ++ show ev
       logPutStrLn $ "Actions posted:" ++ show actions
       logPutStrLn $ "New automation: " ++ show p'
       -- TODO: if no action is posted, accumulate the input and give feedback to the user.
       postActions actions
       when ambiguous $
            postActions [makeAction $ msgE "Keymap was in an ambiguous state! Resetting it."]
       modifiesRef bufferKeymaps (M.insert b bkm { bufferKeymapProcess = if ambiguous then freshP
                                                                         else p'})


changeKeymapE :: Keymap -> YiM ()
changeKeymapE km = do
  modifiesRef defaultKeymap (const km)
  bs <- withEditor getBuffers
  mapM_ (restartBufferThread . bkey) bs
  return ()

-- ---------------------------------------------------------------------
-- Meta operations

-- | Quit.
quitE :: YiM ()
quitE = withUI UI.end

#ifdef DYNAMIC
loadModulesE :: [String] -> YiM (Bool, [String])
loadModulesE modules = do
  withKernel $ \kernel -> do
    targets <- mapM (\m -> guessTarget kernel m Nothing) modules
    setTargets kernel targets
  -- lift $ rts_revertCAFs -- FIXME: GHCi does this; It currently has undesired effects on logging; investigate.
  logPutStrLn $ "Loading targets..."
  result <- withKernel loadAllTargets
  loaded <- withKernel setContextAfterLoad
  ok <- case result of
    GHC.Failed -> withOtherWindow (switchToBufferE =<< getBufferWithName "*console*") >> return False
    _ -> return True
  let newModules = map (moduleNameString . moduleName) loaded
  writesRef editorModules newModules
  logPutStrLn $ "loadModulesE: " ++ show modules ++ " -> " ++ show (ok, newModules)
  return (ok, newModules)

--foreign import ccall "revertCAFs" rts_revertCAFs  :: IO ()
	-- Make it "safe", just in case

tryLoadModulesE :: [String] -> YiM [String]
tryLoadModulesE [] = return []
tryLoadModulesE  modules = do
  (ok, newModules) <- loadModulesE modules
  if ok
    then return newModules
    else tryLoadModulesE (init modules)
    -- when failed, try to drop the most recently loaded module.
    -- We do this because GHC stops trying to load modules upon the 1st failing modules.
    -- This allows to load more modules if we ever try loading a wrong module.

-- | (Re)compile
reloadE :: YiM [String]
reloadE = tryLoadModulesE =<< readsRef editorModules
#endif
-- | Redraw
refreshE :: YiM ()
refreshE = do editor <- with yiEditor readRef
              withUI $ flip UI.refresh editor
              withEditor $ modifyAllA buffersA pendingUpdatesA (const [])

-- | Suspend the program
suspendE :: YiM ()
suspendE = withUI UI.suspend

------------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Window based operations
--

{-
-- | scroll window up
scrollUpE :: YiM ()
scrollUpE = withWindow_ scrollUpW

-- | scroll window down
scrollDownE :: YiM ()
scrollDownE = withWindow_ scrollDownW
-}

-- ---------------------------------------------------------------------
-- registers (TODO these may be redundant now that it is easy to thread
-- state in key bindings, or maybe not.
--

-- | Put string into yank register
setRegE :: String -> YiM ()
setRegE s = withEditor $ modify $ \e -> e { yreg = s }

-- | Return the contents of the yank register
getRegE :: YiM String
getRegE = withEditor $ gets $ yreg

-- ---------------------------------------------------------------------
-- | Dynamically-extensible state components.
--
-- These hooks are used by keymaps to store values that result from
-- Actions (i.e. that restult from IO), as opposed to the pure values
-- they generate themselves, and can be stored internally.
--
-- The `dynamic' field is a type-indexed map.
--

-- | Retrieve a value from the extensible state
getDynamic :: Initializable a => YiM a
getDynamic = withEditor $ getA (dynamicValueA .> dynamicA)

-- | Insert a value into the extensible state, keyed by its type
setDynamic :: Initializable a => a -> YiM ()
setDynamic x = withEditor $ setA (dynamicValueA .> dynamicA) x

------------------------------------------------------------------------
-- | Pipe a string through an external command, returning the stdout
-- chomp any trailing newline (is this desirable?)
--
-- Todo: varients with marks?
--
pipeE :: String -> String -> YiM String
pipeE cmd inp = do
    let (f:args) = split " " cmd
    (out,_err,_) <- lift $ popen f args (Just inp)
    return (chomp "\n" out)


------------------------------------------------------------------------

-- | Same as msgE, but do nothing instead of printing @()@
msgE' :: String -> YiM ()
msgE' "()" = return ()
msgE' s = msgE s

runAction :: Action -> YiM ()
runAction (YiA act) = do
  act >>= msgE' . show
  return ()
runAction (EditorA act) = do
  withEditor act >>= msgE' . show
  return ()
runAction (BufferA act) = do
  withBuffer act >>= msgE' . show
  return ()


-- | Set the cmd buffer, and draw message at bottom of screen
msgE :: String -> YiM ()
msgE = withEditor . printMsg

-- | Show an error on the status line and log it.
errorE :: String -> YiM ()
errorE s = do msgE ("error: " ++ s)
              logPutStrLn $ "errorE: " ++ s

-- | Clear the message line at bottom of screen
msgClrE :: YiM ()
msgClrE = msgE ""


-- | A character to fill blank lines in windows with. Usually '~' for
-- vi-like editors, ' ' for everything else
setWindowFillE :: Char -> EditorM ()
setWindowFillE c = modify $ \e -> e { windowfill = c }

-- | Sets the window style.
setWindowStyleE :: Style.UIStyle -> EditorM ()
setWindowStyleE sty = modify $ \e -> e { uistyle = sty }


-- | Attach the next buffer in the buffer list
-- to the current window.
nextBufW :: YiM ()
nextBufW = withEditor Editor.nextBuffer >>= switchToBufferE

-- | edit the previous buffer in the buffer list
prevBufW :: YiM ()
prevBufW = withEditor Editor.prevBuffer >>= switchToBufferE


-- | Like fnewE, create a new buffer filled with the String @s@,
-- Open up a new window onto this buffer. Doesn't associate any file
-- with the buffer (unlike fnewE) and so is good for popup internal
-- buffers (like scratch)
newBufferE :: String -> String -> YiM BufferRef
newBufferE f s = do
    b <- withEditor $ stringToNewBuffer f s
    switchToBufferE b
    logPutStrLn "newBufferE ended"
    return b

-- | Attach the specified buffer to the current window
switchToBufferE :: BufferRef -> YiM ()
switchToBufferE b = withEditor $ modifyWindows (modifier WS.currentA (\w -> w {bufkey = b}))

-- | Attach the specified buffer to some other window than the current one
switchToBufferOtherWindowE :: BufferRef -> YiM ()
switchToBufferOtherWindowE b = withEditor shiftOtherWindow >> switchToBufferE b

-- | Find buffer with given name. Raise exception if not found.
getBufferWithName :: String -> YiM BufferRef
getBufferWithName = withEditor . getBufferWithName0

-- | Switch to the buffer specified as parameter. If the buffer name is empty, switch to the next buffer.
switchToBufferWithNameE :: String -> YiM ()
switchToBufferWithNameE "" = nextBufW
switchToBufferWithNameE bufName = switchToBufferE =<< getBufferWithName bufName

-- | Return a list of all buffers, and their indicies
listBuffersE :: YiM [(String,Int)]
listBuffersE = do
        bs  <- withEditor getBuffers
        return $ zip (map name bs) [0..]

-- | Release resources associated with buffer
closeBufferE :: String -> YiM ()
closeBufferE bufName = do
  nextB <- withEditor nextBuffer
  b <- withEditor getBuffer
  b' <- if null bufName then return b else getBufferWithName bufName
  switchToBufferE nextB
  withEditor $ deleteBuffer b'

------------------------------------------------------------------------

-- | Close current buffer and window, unless it's the last one.
closeBufferAndWindowE :: EditorM ()
closeBufferAndWindowE = do
  deleteBuffer =<< getBuffer
  tryCloseE

-- | Close the current window.
-- If this is the last window open, quit the program.
closeE :: YiM ()
closeE = do
    n <- withEditor $ withWindows WS.size
    when (n == 1) quitE
    withEditor $ tryCloseE

#ifdef DYNAMIC

-- | Recompile and reload the user's config files
reconfigE :: YiM ()
reconfigE = reloadE >> runConfig

runConfig :: YiM ()
runConfig = do
  loaded <- withKernel $ \kernel -> do
              let cfgMod = mkModuleName kernel "YiConfig"
              isLoaded kernel cfgMod
  if loaded
   then do result <- withKernel $ \kernel -> evalMono kernel "YiConfig.yiMain :: Yi.Yi.YiM ()"
           case result of
             Nothing -> errorE "Could not run YiConfig.yiMain :: Yi.Yi.YiM ()"
             Just x -> x
   else errorE "YiConfig not loaded"

loadE :: String -> YiM [String]
loadE modul = do
  logPutStrLn $ "loadE: " ++ modul
  ms <- readsRef editorModules
  tryLoadModulesE (if Data.List.notElem modul ms then ms++[modul] else ms)

unloadE :: String -> YiM [String]
unloadE modul = do
  ms <- readsRef editorModules
  tryLoadModulesE $ delete modul ms

getNamesInScopeE :: YiM [String]
getNamesInScopeE = do
  withKernel $ \k -> do
      rdrNames <- getRdrNamesInScope k
      names <- getNamesInScope k
      return $ map (nameToString k) rdrNames ++ map (nameToString k) names

ghcErrorReporter :: Yi -> GHC.Severity -> SrcLoc.SrcSpan -> Outputable.PprStyle -> ErrUtils.Message -> IO ()
ghcErrorReporter yi severity srcSpan pprStyle message =
    -- the following is written in very bad style.
    flip runReaderT yi $ do
      e <- readEditor id
      let [b] = findBufferWithName "*console*" e
      withGivenBuffer b $ savingExcursionB $ do
        moveTo =<< getMarkPointB =<< getMarkB (Just "errorInsert")
        insertN msg
        insertN "\n"
    where msg = case severity of
                  GHC.SevInfo -> show (message pprStyle)
                  GHC.SevFatal -> show (message pprStyle)
                  _ -> show ((ErrUtils.mkLocMessage srcSpan message) pprStyle)


-- | Run a (dynamically specified) editor command.
execE :: String -> YiM ()
execE s = do
  ghcErrorHandlerE $ do
            result <- withKernel $ \kernel -> do
                               logPutStrLn $ "execing " ++ s
                               evalMono kernel ("makeAction (" ++ s ++ ") :: Yi.Yi.Action")
            case result of
              Left err -> errorE err
              Right x -> do runAction x
                            return ()

-- | Install some default exception handlers and run the inner computation.
ghcErrorHandlerE :: YiM () -> YiM ()
ghcErrorHandlerE inner = do
  flip catchDynE (\dyn -> do
  		    case dyn of
		     GHC.PhaseFailed _ code -> errorE $ "Exitted with " ++ show code
		     GHC.Interrupted -> errorE $ "Interrupted!"
		     _ -> do errorE $ "GHC exeption: " ++ (show (dyn :: GHC.GhcException))

	    ) $
            inner

#else
reloadE = msgE "reloadE: Not supported"
execE s = msgE "execE: Not supported"
reconfigE = msgE "reconfigE: Not supported"

getNamesInScopeE :: YiM [String]
getNamesInScopeE = return []
#endif

withOtherWindow :: YiM () -> YiM ()
withOtherWindow f = do
  withEditor $ shiftOtherWindow
  f
  withEditor $ prevWinE
