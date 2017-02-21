-- |
-- Module      :  System.Hapistrano.Core
-- Copyright   :  © 2015-2017 Stack Builders
-- License     :  MIT
--
-- Maintainer  :  Justin Leitgeb <justin@stackbuilders.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- Core Hapistrano functions that provide basis on which all the
-- functionality is built.

{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.Hapistrano.Core
  ( runHapistrano
  , failWith
  , exec
  , scpFile
  , scpDir )
where

import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.Proxy
import Path
import System.Exit
import System.Hapistrano.Commands
import System.Hapistrano.Types
import System.IO
import System.Process

-- | Run the 'Hapistrano' monad. The monad hosts 'exec' actions.

runHapistrano :: MonadIO m
  => Maybe SshOptions  -- ^ SSH options to use or 'Nothing' if we run locally
  -> Hapistrano a      -- ^ The computation to run
  -> m a               -- ^ IO-enabled monad that hosts the computation
runHapistrano sshOptions m = liftIO $ do
  let config = Config
        { configSshOptions = sshOptions }
  r <- runReaderT (runExceptT m) config
  case r of
    Left (Failure n msg) -> do
      forM_ msg (hPutStrLn stderr)
      exitWith (ExitFailure n)
    Right x ->
      x <$ putStrLn "Success."

-- | Fail returning the following status code and printing given message to
-- 'stderr'.

failWith :: Int -> Maybe String -> Hapistrano a
failWith n msg = throwError (Failure n msg)

-- | Run the given sequence of command. Whether to use SSH or not is
-- determined from settings contained in the 'Hapistrano' monad
-- configuration. Commands that return non-zero exit codes will result in
-- short-cutting of execution.

exec :: forall a. Command a => a -> Hapistrano (Result a)
exec typedCmd = do
  Config {..} <- ask
  let (prog, args) =
        case configSshOptions of
          Nothing ->
            ("bash", ["-c", cmd])
          Just SshOptions {..} ->
            ("ssh", [sshHost, "-p", show sshPort, cmd])
      cmd = renderCommand typedCmd
  parseResult (Proxy :: Proxy a) <$> exec' prog args cmd

-- | Copy a file from local path to target server.

scpFile
  :: Path Abs File     -- ^ Location of the file to copy
  -> Path Abs File     -- ^ Where to put the file on target machine
  -> Hapistrano ()
scpFile src dest =
  scp' (fromAbsFile src) (fromAbsFile dest) ["-q"]

-- | Copy a local directory recursively to target server.

scpDir
  :: Path Abs Dir      -- ^ Location of the directory to copy
  -> Path Abs Dir      -- ^ Where to put the dir on target machine
  -> Hapistrano ()
scpDir src dest =
  scp' (fromAbsDir src) (fromAbsDir dest) ["-qr"]

scp'
  :: FilePath
  -> FilePath
  -> [String]
  -> Hapistrano ()
scp' src dest extraArgs = do
  Config {..} <- ask
  let prog = "scp"
      portArg =
        case sshPort <$> configSshOptions of
          Nothing -> []
          Just x  -> ["-P", show x]
      hostPrefix =
        case sshHost <$> configSshOptions of
          Nothing -> ""
          Just x -> x ++ ":"
      args = extraArgs ++ portArg ++ [src, hostPrefix ++ dest]
  void (exec' prog args (prog ++ " " ++ unwords args))

----------------------------------------------------------------------------
-- Helpers

-- | A helper for 'exec' and similar functions.

exec'
  :: String            -- ^ Name of program to run
  -> [String]          -- ^ Arguments to that program
  -> String            -- ^ How to show the command in print-outs
  -> Hapistrano String -- ^ Raw stdout output of that program
exec' prog args cmd = do
  Config {..} <- ask
  let hostLabel =
        case configSshOptions of
          Nothing              -> "localhost"
          Just SshOptions {..} -> sshHost ++ ":" ++ show sshPort
  liftIO $ do
    printLine hostLabel
    putStrLn ("$ " ++ cmd)
  (exitCode, stdout', stderr') <- liftIO
    (readProcessWithExitCode prog args "")
  unless (null stdout') . liftIO $
    putStrLn stdout'
  unless (null stderr') . liftIO $
    hPutStrLn stderr stderr'
  case exitCode of
    ExitSuccess ->
      return stdout'
    ExitFailure n ->
      failWith n Nothing

-- | Print something “inside” a line, sort-of beautifully.

printLine :: String -> IO ()
printLine str = putStrLn ("*** " ++ str ++ padding)
  where
    padding = ' ' : replicate (75 - length str) '*'
