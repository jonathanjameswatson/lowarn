module Lowarn.ExamplePrograms.Following.Following3
  ( program,
    User (..),
  )
where

import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import qualified Lowarn.ExamplePrograms.Following.Following2 as PreviousVersion
import Lowarn.Runtime (Program (..), RuntimeData, isUpdateAvailable, lastState)
import System.IO
  ( Handle,
    hFlush,
    hGetLine,
    hPrint,
    hPutStrLn,
    stdin,
    stdout,
  )
import Text.Regex.TDFA

newtype User = User
  { _tag :: String
  }

instance Show User where
  show (User tag) = tag

data State = State
  { _users :: [User],
    _in :: Handle,
    _out :: Handle
  }

transformer :: PreviousVersion.State -> IO (Maybe State)
transformer (PreviousVersion.State users in_ out) =
  return $ Just $ State users' in_ out
  where
    users' = reverse $ toList $ fmap (User . show) users

program :: Program State PreviousVersion.State
program =
  Program
    ( \runtimeData ->
        eventLoop runtimeData $
          fromMaybe (State [] stdin stdout) (lastState runtimeData)
    )
    transformer

eventLoop :: RuntimeData a -> State -> IO State
eventLoop runtimeData state@(State users in_ out) = do
  continue <- isUpdateAvailable runtimeData
  if not continue
    then do
      hPutStrLn out "Following:"
      mapM_ (hPrint out) $ reverse users
      hPutStrLn out "------"
      tag <- User <$> getTag
      eventLoop runtimeData $ state {_users = tag : users}
    else return state
  where
    getTag :: IO String
    getTag = do
      hPutStrLn out "Input tag of user to follow:"
      hFlush out
      tag <- hGetLine in_
      if tag =~ "\\`[a-zA-Z]+#[0-9]{4}\\'"
        then return tag
        else hPutStrLn out "Invalid tag, try again." >> getTag