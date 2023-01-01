{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module                  : Lowarn.Linker
-- SPDX-License-Identifier : MIT
-- Stability               : experimental
-- Portability             : non-portable (POSIX, GHC)
--
-- Module for interacting with GHC to link modules and load their entities.
module Lowarn.Linker
  ( -- * Monad
    Linker,
    runLinker,
    liftIO,

    -- * Actions
    load,
    updatePackageDatabase,
  )
where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO)
import Data.List (minimumBy)
import Data.Ord (comparing)
import GHC hiding (load, moduleName)
import GHC.Data.FastString
import GHC.Driver.Monad
import GHC.Driver.Session
import GHC.Paths (libdir)
import GHC.Runtime.Interpreter
import GHC.Runtime.Linker
import GHC.Types.Name
import GHC.Types.Unique
import GHC.Unit hiding (moduleName)
import System.Environment (lookupEnv)
import System.FilePath.Glob (CompOptions (..), compileWith, globDir1)
import Text.Printf (printf)
import Unsafe.Coerce (unsafeCoerce)

-- | Monad for linking modules from the package database and accessing their
-- exported entities.
newtype Linker a = Linker
  { unLinker :: Ghc a
  }
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Run a linker.
runLinker :: Linker a -> IO a
runLinker linker =
  defaultErrorHandler defaultFatalMessager defaultFlushOut $
    runGhc (Just libdir) $ do
      flags <- getSessionDynFlags
      flags' <-
        liftIO $
          lookupEnv "LOWARN_PACKAGE_ENV"
            >>= \case
              Just "" -> return flags
              Nothing -> return flags
              Just lowarnPackageEnv -> do
                interpretPackageEnv $ flags {packageEnv = Just lowarnPackageEnv}
      void $ setSessionDynFlags $ flags' {ghcLink = LinkStaticLib}
      liftIO . initDynLinker =<< getSession
      unLinker linker

-- | Action that gives an entity exported by a module in a package in the
-- package database. The module is linked if it hasn't already been. @Nothing@
-- is given if the module or package cannot be found.
load ::
  -- | The name of the package to find the module in.
  String ->
  -- | The name of the module to find.
  String ->
  -- | The name of the entity to take from the module.
  String ->
  Linker (Maybe a)
load packageName' moduleName' symbol = Linker $ do
  flags <- getSessionDynFlags
  session <- getSession

  let moduleName = mkModuleName moduleName'
      packageName = PackageName $ mkFastString packageName'

  liftIO $
    lookupUnitInfo flags packageName moduleName
      >>= maybe
        (return Nothing)
        ( \unitInfo -> liftIO $ do
            let unit = mkUnit unitInfo
            let module_ = mkModule unit moduleName
            let name =
                  mkExternalName
                    (mkBuiltinUnique 0)
                    module_
                    (mkVarOcc symbol)
                    noSrcSpan

            linkModule session module_

            value <- withInterp session $
              \interp -> getHValue session name >>= wormhole interp
            return $ Just $ unsafeCoerce value
        )

-- | Action that updates the package database. This uses the package environment
-- if it is specified. This can be set with the @LOWARN_PACKAGE_ENV@ environment
-- variable. If the package environment is not set, the package database is
-- instead updated by resetting the unit state and unit databases.
updatePackageDatabase :: Linker ()
updatePackageDatabase = Linker $ do
  flags <- getSessionDynFlags
  flagsWithInterpretedPackageEnv <- case packageEnv flags of
    Nothing ->
      return $ flags {unitState = emptyUnitState, unitDatabases = Nothing}
    Just _ -> do
      liftIO $ interpretPackageEnv flags
  setSessionDynFlags =<< liftIO (initUnits flagsWithInterpretedPackageEnv)

lookupUnitInfo :: DynFlags -> PackageName -> ModuleName -> IO (Maybe UnitInfo)
lookupUnitInfo flags packageName moduleName = do
  case exposedModulesAndPackages of
    [] -> do
      putStrLn $ "Can't find module " <> moduleNameString moduleName
      return Nothing
    (_, unitInfo) : _ -> return $ Just unitInfo
  where
    modulesAndPackages = lookupModuleInAllUnits (unitState flags) moduleName
    exposedModulesAndPackages =
      filter
        ( \(_, unitInfo) ->
            unitIsExposed unitInfo && unitPackageName unitInfo == packageName
        )
        modulesAndPackages

findArchiveFile :: UnitInfo -> IO (Maybe FilePath)
findArchiveFile unitInfo = do
  archiveFiles <-
    concat
      <$> sequence
        [ let pattern =
                compileWith compOptions $
                  printf "%s/libHS%s*.a" searchDir packageName
           in globDir1 pattern searchDir
          | searchDir <- searchDirs
        ]
  return $ case archiveFiles of
    [] -> Nothing
    _ : _ -> Just $ minimumBy (comparing length) archiveFiles
  where
    searchDirs = unitLibraryDirs unitInfo
    packageName = unpackFS $ unPackageName $ unitPackageName unitInfo
    compOptions =
      CompOptions
        { characterClasses = False,
          characterRanges = False,
          numberRanges = False,
          wildcards = True,
          recursiveWildcards = False,
          pathSepInRanges = False,
          errorRecovery = True
        }

findDependencyUnitInfo :: DynFlags -> UnitInfo -> [UnitInfo]
findDependencyUnitInfo flags rootUnitInfo =
  transitiveClosure [rootUnitInfo] (Set.singleton $ unitId rootUnitInfo) []
  where
    transitiveClosure :: [UnitInfo] -> Set UnitId -> [UnitInfo] -> [UnitInfo]
    transitiveClosure [] _ acc = acc
    transitiveClosure (unitInfo : unvisitedDependencies) seenDependencyIds acc =
      transitiveClosure
        (newUnvisitedDependencies ++ unvisitedDependencies)
        (Set.union seenDependencyIds $ Set.fromList newUnvisitedDependencyIds)
        (unitInfo : acc)
      where
        dependencyIds = unitDepends unitInfo
        newUnvisitedDependencyIds =
          filter (`Set.notMember` seenDependencyIds) dependencyIds
        newUnvisitedDependencies =
          mapMaybe (lookupUnitId $ unitState flags) newUnvisitedDependencyIds
