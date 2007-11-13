#!/usr/bin/env runhaskell
module Main where

import Control.Applicative
import Control.Monad
import Data.List
import Data.Maybe
import Distribution.PackageDescription
import Distribution.Simple
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Program
import Distribution.Simple.Setup
import System.Directory
import System.FilePath
import System.IO

main :: IO ()
main = defaultMainWithHooks defaultUserHooks
       { buildHook = bHook, instHook = install }

mkOpt :: (String, String) -> String
mkOpt (name,def) = "-D" ++ name ++ "=" ++ def

-- TODO: add a configuration hook that does not want to build for
-- certain combination of flags


bHook :: PackageDescription -> LocalBuildInfo -> UserHooks -> BuildFlags -> IO ()
bHook pd lbi hooks flags = do
  let verbosity = buildVerbose flags
  let dataPref = mkDataDir pd lbi NoCopyDest
      pkgOpts = concat [ ["-package", showPackageId pkg] | pkg <- packageDeps lbi ]
      ghcOut = rawSystemProgramStdoutConf verbosity ghcProgram (withPrograms lbi)
  print dataPref
  libdr <- head . lines <$> ghcOut ["--print-libdir"]
  putStrLn $ "GHC libdir = " ++ show libdr
  let pbi = (Nothing,
       [("yi", emptyBuildInfo
         { options = [(GHC,[mkOpt ("GHC_LIBDIR",show libdr), 
                            mkOpt ("YI_LIBDIR", show dataPref),
                            mkOpt ("YI_PKG_OPTS", show pkgOpts)])] })])
      pd' = updatePackageDescription pbi pd
  buildHook defaultUserHooks pd' lbi hooks flags
  mapM_ (precompile pd' lbi verbosity flags) precompiles

dependencyName :: Dependency -> String
dependencyName (Dependency name _) = name

precompile :: PackageDescription -> LocalBuildInfo -> t -> BuildFlags -> ([Char], [String]) -> IO ()
precompile pd lbi _ bflags (moduleName, dependencies) = when ok $ do
  -- just pretend that we build a library with the given modules
  putStrLn ("Precompiling " ++ moduleName)
  let [Executable "yi" _ yiBuildInfo] = executables pd
      pd' = pd {package = PackageIdentifier "main" (Version [] []),
                          -- we pretend we build package main, so that GHCi
                          -- can associate the source files and the precompiled modules
                executables = [],
                library = Just (Library {exposedModules = [moduleName],
                                         libBuildInfo = yiBuildInfo})}
  buildHook defaultUserHooks pd' lbi defaultUserHooks bflags -- {buildVerbose = deafening }
     where availablePackages = map dependencyName $ buildDepends pd
           ok = all (`elem` availablePackages) dependencies

precompiles :: [(String, [String])]
precompiles = [("Yi.Main", []),
               ("Yi.Keymap.Emacs", []),
               ("Yi.Keymap.Vim", []),
               ("Yi.Vty.UI", ["vty"]),
               ("Yi.Gtk.UI", ["gtk"]),
               ("Yi.Dired", [])]

install :: PackageDescription -> LocalBuildInfo -> UserHooks -> InstallFlags -> IO ()
install pd lbi hooks flags = do
  curdir <- getCurrentDirectory
  allFiles0 <- mapM unixFind $ map (curdir </>) $ ["Yi", foldl1 (</>) ["dist","build","Yi"]]
  let allFiles = map (makeRelative curdir) $ nub $ concat allFiles0
      sourceFiles = filter ((`elem` [".hs-boot",".hs",".hsinc"]) . takeExtension) allFiles
      targetFiles = filter ((`elem` [".hi",".o"]) . takeExtension) allFiles
      --NOTE: It's important that source files are copied before target files,
      -- otherwise GHC (via Yi) thinks it has to recompile them when Yi is started.
      pd' = pd {dataFiles = dataFiles pd ++ sourceFiles ++ targetFiles}
  instHook defaultUserHooks pd' lbi hooks flags

unixFind :: FilePath -> IO [FilePath]
unixFind dir = do
  contents0 <- getDirectoryContents dir
  let contents = map (dir </>) $ filter (not . (`elem` [".", ".."])) contents0
  -- putStrLn $ dir ++ " > " ++ show contents0
  dirs <- filterM doesDirectoryExist contents
  files <- filterM doesFileExist contents
  rec <- mapM unixFind dirs
  return (files ++ concat rec)
