{-# LANGUAGE ScopedTypeVariables, FlexibleInstances, MultiParamTypeClasses, UndecidableInstances #-}

-- Copyright (c) 2005,2007,2008 Jean-Philippe Bernardy

{-
  This module is aimed at being a helper for the Emacs keybindings.
  In particular this should be useful for anyone that has a custom
  keymap derived from or based on the Emacs one.
-}

module Yi.Keymap.Emacs.Utils
  ( KList
  , makeKeymap
  , makePartialKeymap

  , askQuitEditor
  , modifiedQuitEditor
  , adjIndent
  , changeBufferNameE
  , rebind
  , withMinibuffer
  , queryReplaceE
  , isearchKeymap
  , shellCommandE
  , cabalConfigureE
  , cabalBuildE
  , reloadProjectE
  , executeExtendedCommandE
  , evalRegionE
  , readArgC
  , scrollDownE
  , scrollUpE
  , switchBufferE
  , killBufferE
  , insertSelf
  , insertNextC
  , insertTemplate
  , findFile
  , completeFileName
  , completeBufferName
  )
where

{- Standard Library Module Imports -}
import Control.Monad
  ()
import Data.Char
  ( ord
  , isDigit
  )
import Data.List
  ( isPrefixOf
  , (\\)
  )
import Data.Maybe
  ( fromMaybe )
import System.Exit
  ( ExitCode( ExitSuccess,ExitFailure ) )
import System.FriendlyPath
import System.FilePath
  ( takeDirectory
  , (</>)
  , addTrailingPathSeparator
  , hasTrailingPathSeparator
  , takeFileName
  )
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getDirectoryContents
  , getCurrentDirectory
  , setCurrentDirectory
  )
import Control.Monad.Trans (MonadIO (..))
import Control.Monad
{- External Library Module Imports -}
{- Local (yi) module imports -}


import Control.Applicative
import Control.Monad
import Yi.Buffer
import Yi.Buffer.HighLevel
import Yi.Buffer.Region
import Yi.Completion
import Yi.Core
import Yi.Debug
import Yi.Dired
import Yi.Editor
import Yi.Eval
import Yi.Event
import Yi.File
import Yi.Interact hiding (write)
import Yi.Keymap.Emacs.Keys
import Yi.Keymap.Emacs.UnivArgument
import Yi.MiniBuffer
import Yi.Process
import Yi.Search
import Yi.Templates
  ( addTemplate
  , templateNames
  )
import Yi.UI.Common 

{- End of Module Imports -}

----------------------------
-- | Quits the editor if there are no unmodified buffers
-- if there are unmodified buffers then we ask individually for
-- each modified buffer whether or not the user wishes to save
-- it or not. If we get to the end of this list and there are still
-- some modified buffers then we ask again if the user wishes to
-- quit, but this is then a simple yes or no.
askQuitEditor :: YiM ()
askQuitEditor = askIndividualQuit =<< getModifiedBuffers

getModifiedBuffers :: YiM [FBuffer]
getModifiedBuffers = filterM isFileBuffer =<< filter (not . isUnchangedBuffer) <$> withEditor getBuffers

-- | Is there a proper file associated with the buffer?
-- In other words, does it make sense to offer to save it?
isFileBuffer :: (Functor m, MonadIO m) => FBuffer -> m Bool
isFileBuffer b = case file b of
                   Nothing -> return False
                   Just fn -> not <$> liftIO (doesDirectoryExist fn)
                     
--------------------------------------------------
-- Takes in a list of buffers which have been identified
-- as modified since their last save.
askIndividualQuit :: [FBuffer] -> YiM ()
askIndividualQuit [] = modifiedQuitEditor
askIndividualQuit (firstBuffer : others) =
  spawnMinibufferE saveMessage askKeymap >> return ()
  where
  askKeymap   = const $ makeKeymap askBindings
  saveMessage = concat [ "do you want to save the buffer: "
                       , bufferName
                       , "? (y/n/q/c)"
                       ]
  bufferName  = name firstBuffer

  askBindings = [ ("n", write noAction)
                , ( "y", write yesAction )
                , ( "c", write closeBufferAndWindowE )
                , ( "q", write quitEditor )
                ]
  yesAction   = do fwriteBufferE firstBuffer
                   withEditor closeBufferAndWindowE
                   askIndividualQuit others

  noAction    = do withEditor closeBufferAndWindowE
                   askIndividualQuit others

---------------------------
-- | Quits the editor if there are no unmodified buffers
-- if there are then simply confirms with the user that they
-- with to quit.
modifiedQuitEditor :: YiM ()
modifiedQuitEditor =
  do modifiedBuffers <- getModifiedBuffers
     if null modifiedBuffers
        then quitEditor
        else spawnMinibufferE modifiedMessage askKeymap >> return ()
  where
  modifiedMessage = "Modified buffers exist really quit? (y/n)"

  askKeymap       = const $ makeKeymap askBindings
  askBindings     = [ ("n", write noAction)
                    , ("y", write $ quitEditor)
                    ]

  noAction        = closeBufferAndWindowE

-- | A simple wrapper to adjust the current indentation using
-- the mode specific indentation function but according to the
-- given indent behaviour.
adjIndent :: IndentBehaviour -> YiM ()
adjIndent ib = withMode (\m -> modeIndent m ib)


---------------------------
-- | Changing the buffer name quite useful if you have
-- several the same.

changeBufferNameE :: YiM ()
changeBufferNameE =
  withMinibuffer "New buffer name:" return strFun
  where
  strFun :: String -> YiM ()
  strFun = withBuffer . setnameB

----------------------------
-- | shell-command
shellCommandE :: YiM ()
shellCommandE = do
    withMinibuffer "Shell command:" return $ \cmd -> do
      (cmdOut,cmdErr,exitCode) <- liftIO $ runShellCommand cmd
      case exitCode of
        ExitSuccess -> withEditor $ newBufferE "*Shell Command Output*" cmdOut >> return ()
        ExitFailure _ -> msgEditor cmdErr

----------------------------
-- | find the first file in the list which exists in the current directory
chooseExistingFile :: [String] -> YiM String
chooseExistingFile []     = return ""
chooseExistingFile (x:xs) = do
  haveFile <- liftIO $ doesFileExist x
  if haveFile then return x else chooseExistingFile xs

cabalSetupFiles :: [String]
cabalSetupFiles = ["Setup.lhs", "Setup.hs"]

----------------------------
-- cabal-configure
cabalConfigureE :: YiM ()
cabalConfigureE =
    withMinibuffer "Project directory:" (completeFileName Nothing) $ \fpath ->
    withMinibuffer "Configure args:" return $ \cmd -> do
      liftIO $ setCurrentDirectory fpath
      setupFile <- chooseExistingFile cabalSetupFiles
      if setupFile == "" then msgEditor "could not locate Setup.lhs or Setup.hs"
       else do
         (cmdOut,cmdErr,exitCode) <- liftIO $ popen "runhaskell" (setupFile:"configure":words cmd) Nothing
         case exitCode of
           ExitSuccess   -> do withUI $ \ui -> reloadProject ui "."
                               withEditor $ withOtherWindow $ newBufferE "*Shell Command Output*" cmdOut >> return ()
           ExitFailure _ -> msgEditor cmdErr

reloadProjectE :: String -> YiM ()
reloadProjectE s = withUI $ \ui -> reloadProject ui s

----------------------------
-- cabal-build
cabalBuildE :: YiM ()
cabalBuildE =
    withMinibuffer "Build args:" return $ \cmd -> do
      setupFile <- chooseExistingFile cabalSetupFiles
      if setupFile == "" then msgEditor "could not locate Setup.lhs or Setup.hs"
        else startSubprocess "runhaskell" (setupFile:"build":words cmd)

-----------------------------
-- isearch
selfSearchKeymap :: Keymap
selfSearchKeymap = do
  Event (KASCII c) [] <- satisfy (const True)
  write (isearchAddE [c])

searchKeymap :: Keymap
searchKeymap = selfSearchKeymap <|> makeKeymap
               [ -- ("C-g", isearchDelE) -- Only if string is not empty.
                 ("C-r", write isearchPrevE)
               , ("C-s", write isearchNextE)
               , ("C-w", write isearchWordE)
               , ("C-n", write $ isearchAddE "\n")
               , ("M-p", write $ isearchHistory 1)
               , ("M-n", write $ isearchHistory (-1))
               , ("BACKSP", write $ isearchDelE)
               ]

isearchKeymap :: Direction -> Keymap
isearchKeymap direction = 
  do write $ isearchInitE direction
     many searchKeymap
     makePartialKeymap [ ("C-g", write isearchCancelE)
                       , ("C-m", write isearchFinishE)
                       , ("RET", write isearchFinishE)
                       ]
                       (write isearchFinishE)

----------------------------
-- query-replace
queryReplaceE :: YiM ()
queryReplaceE = do
    withMinibuffer "Replace:" return $ \replaceWhat -> do
    withMinibuffer "With:" return $ \replaceWith -> do
    b <- withEditor $ getBuffer
    let replaceBindings = [("n", write $ qrNext b replaceWhat),
                           ("y", write $ qrReplaceOne b replaceWhat replaceWith),
                           ("q", write $ closeBufferAndWindowE),
                           ("C-g", write $ closeBufferAndWindowE)
                           ]
    spawnMinibufferE
            ("Replacing " ++ replaceWhat ++ "with " ++ replaceWith ++ " (y,n,q):")
            (const (makeKeymap replaceBindings))
    qrNext b replaceWhat

executeExtendedCommandE :: YiM ()
executeExtendedCommandE = do
  withMinibuffer "M-x" completeFunctionName execEditorAction

evalRegionE :: YiM ()
evalRegionE = do
  withBuffer (getSelectRegionB >>= readRegionB) >>= return -- FIXME: do something sensible.
  return ()

-- * Code for various commands
-- This ideally should be put in their own module,
-- without a prefix, so M-x ... would be easily implemented
-- by looking up that module's contents


insertSelf :: Char -> YiM ()
insertSelf = repeatingArg . insertB

insertNextC :: KeymapM ()
insertNextC = do c <- satisfy (const True)
                 write $ repeatingArg $ insertB (eventToChar c)


-- Inserting a template from the templates defined in Yi.Templates.hs
insertTemplate :: YiM ()
insertTemplate =
  withMinibuffer "template-name:" completeTemplateName $ withEditor . addTemplate
  where
  completeTemplateName :: String -> YiM String
  completeTemplateName s = withEditor $ completeInList s (isPrefixOf s) templateNames

-- | C-u stuff
readArgC :: KeymapM ()
readArgC = do readArg' Nothing
              write $ do UniversalArg u <- withEditor getDynamic
                         logPutStrLn (show u)
                         msgEditor ""

readArg' :: Maybe Int -> KeymapM ()
readArg' acc = do
    write $ msgEditor $ "Argument: " ++ show acc
    c <- satisfy (const True) -- FIXME: the C-u will read one character that should be part of the next command!
    case c of
      Event (KASCII d) [] | isDigit d -> readArg' $ Just $ 10 * (fromMaybe 0 acc) + (ord d - ord '0')
      _ -> write $ setDynamic $ UniversalArg $ Just $ fromMaybe 4 acc


-- | Open a file using the minibuffer. We have to set up some stuff to allow hints
--   and auto-completion.
findFile :: YiM ()
findFile = do maybePath <- withBuffer getfileB
              startPath <- addTrailingPathSeparator <$> (liftIO $ canonicalizePath' =<< getFolder maybePath)
              withMinibufferGen startPath (findFileHint startPath) "find file:" (completeFileName (Just startPath)) $ \filename -> do
                msgEditor $ "loading " ++ filename
                fnewE filename

-- | For use as the hint when opening a file using the minibuffer.
-- We essentially return all the files in the given directory which
-- have the given prefix.
findFileHint :: String -> String -> YiM String
findFileHint startPath s = 
  liftM (show . snd) $ getAppropriateFiles (Just startPath) s

-- | Given a possible starting path (which if not given defaults to
--   the current directory) and a fragment of a path we find all
--   files within the given (or current) directory which can complete
--   the given path fragment.
--   We return a pair of both directory plus the filenames on their own
--   that is without their directories. The reason for this is that if
--   we return all of the filenames then we get a 'hint' which is way too
--   long to be particularly useful.
getAppropriateFiles :: Maybe String -> String -> YiM (String, [ String ])
getAppropriateFiles start s = do
  curDir <- case start of
            Nothing -> do bufferPath <- withBuffer getfileB
                          liftIO $ getFolder bufferPath
            (Just path) -> return path
  let sDir = if hasTrailingPathSeparator s then s else takeDirectory s
      searchDir = if null sDir then curDir
                  else if isAbsolute' sDir then sDir
                  else curDir </> sDir
  searchDir' <- liftIO $ expandTilda searchDir
  let fixTrailingPathSeparator f = do
                       isDir <- doesDirectoryExist (searchDir' </> f)
                       return $ if isDir then addTrailingPathSeparator f else f
  files <- liftIO $ getDirectoryContents searchDir'
  -- Remove the two standard current-dir and parent-dir as we do not
  -- need to complete or hint about these as they are known by users.
  let files' = files \\ [ ".", ".." ]
  fs <- liftIO $ mapM fixTrailingPathSeparator files
  let matching = filter (isPrefixOf $ takeFileName s) fs
  return (sDir, matching)


-- | Given a possible path and a prefix complete as much of the file name
--   as can be worked out from teh path and the prefix. 
completeFileName :: Maybe String -> String -> YiM String
completeFileName start s = do
  (sDir, files) <- getAppropriateFiles start s
  withEditor $ completeInList s (isPrefixOf s) $ map (sDir </>) files

 
 -- | Given a path, trim the file name bit if it exists.  If no path given,
 -- | return current directory
getFolder :: Maybe String -> IO String
getFolder Nothing     = getCurrentDirectory
getFolder (Just path) = do
  isDir <- doesDirectoryExist path
  let dir = if isDir then path else takeDirectory path
  if null dir then getCurrentDirectory else return dir



-- debug :: String -> Keymap
-- debug = write . logPutStrLn

completeBufferName :: String -> YiM String
completeBufferName s = withEditor $ do
  bs <- getBuffers
  completeInList s (isPrefixOf s) (map name bs)


completeFunctionName :: String -> YiM String
completeFunctionName s = do
  names <- getAllNamesInScope
  withEditor $ completeInList s (isPrefixOf s) names

scrollDownE :: YiM ()
scrollDownE = withUnivArg $ \a -> withBuffer $
              case a of
                 Nothing -> downScreenB
                 Just n -> replicateM_ n lineDown

scrollUpE :: YiM ()
scrollUpE = withUnivArg $ \a -> withBuffer $
              case a of
                 Nothing -> upScreenB
                 Just n -> replicateM_ n lineUp

switchBufferE :: YiM ()
switchBufferE = do
  bs <- withEditor (map name . tail <$> getBufferStack)
  withMinibufferFin  "switch to buffer:" bs (withEditor . switchToBufferWithNameE)


killBufferE :: YiM ()
killBufferE = withMinibuffer "kill buffer:" completeBufferName $ withEditor . closeBufferE
