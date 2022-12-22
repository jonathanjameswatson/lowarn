{-# LANGUAGE PackageImports #-}

module Transformer_following
  ( transformer,
  )
where

import Control.Arrow (first)
import qualified Data.Sequence as Seq
import Lowarn.Runtime (Transformer (Transformer))
import System.Random (mkStdGen, randomR)
import System.Random.Stateful (applyIOGen, newIOGenM)
import qualified "lowarn-version-following-v1v0v0" Lowarn.ExampleProgram.Following as PreviousVersion
import qualified "lowarn-version-following-v2v0v0" Lowarn.ExampleProgram.Following as NextVersion

transformer :: Transformer PreviousVersion.State NextVersion.State
transformer = Transformer $
  \(PreviousVersion.State users inHandle outHandle) -> do
    ioGen <- newIOGenM (mkStdGen 0)
    users' <-
      Seq.fromList
        <$> mapM
          ( \(PreviousVersion.User nickname) ->
              applyIOGen
                (first (NextVersion.User nickname) . randomR (1, 9999))
                ioGen
          )
          users
    return $ Just $ NextVersion.State users' inHandle outHandle
