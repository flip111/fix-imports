-- | Main file for FixImports that uses the default formatting.  It reads
-- a config file from the current directory.
--
-- More documentation in "FixImports".
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import qualified Control.Exception as Exception
import Control.Monad (when)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO

import qualified System.Console.GetOpt as GetOpt
import qualified System.Environment as Environment
import qualified System.Exit as Exit
import qualified System.IO as IO

import qualified Config
import qualified FixImports
import qualified Types
import qualified Util


main :: IO ()
main = do
    (config, errors) <- readConfig ".fix-imports"
    mapM_ (Text.IO.hPutStrLn IO.stderr) errors
    mainConfig config

readConfig :: FilePath -> IO (Config.Config, [Text.Text])
readConfig = fmap (maybe (Config.empty, []) Config.parse)
    . Util.catchENOENT . Text.IO.readFile

mainConfig :: Config.Config -> IO ()
mainConfig config = do
    -- I need the module path to search for modules relative to it first.  I
    -- could figure it out from the parsed module name, but a main module may
    -- not have a name.
    (modulePath, (verbose, debug, includes)) <-
        parseArgs =<< Environment.getArgs
    source <- IO.getContents
    config <- return $ config
        { Config._includes = includes ++ Config._includes config
        , Config._debug = debug
        }
    fixed <- FixImports.fixModule config modulePath source
        `Exception.catch` (\(exc :: Exception.SomeException) ->
            return $ Left $ "exception: " ++ show exc)
    case fixed of
        Left err -> do
            IO.putStr source
            IO.hPutStrLn IO.stderr $ "error: " ++ err
            Exit.exitFailure
        Right (FixImports.Result source added removed metrics) -> do
            IO.putStr source
            let names = Util.join ", " . map Types.moduleName . Set.toList
                (addedMsg, removedMsg) = (names added, names removed)
            done <- FixImports.metric "done"
            Config.debug config $ Text.stripEnd $
                FixImports.showMetrics (done : metrics)
            when (verbose && (not (null addedMsg) || not (null removedMsg))) $
                IO.hPutStrLn IO.stderr $ Util.join "; " $ filter (not . null)
                    [ if null addedMsg then "" else "added: " ++ addedMsg
                    , if null removedMsg then "" else "removed: " ++ removedMsg
                    ]
            Exit.exitSuccess

data Flag = Debug | Include String | Verbose
    deriving (Eq, Show)

options :: [GetOpt.OptDescr Flag]
options =
    [ GetOpt.Option [] ["debug"] (GetOpt.NoArg Debug)
        "print debugging info on stderr"
    , GetOpt.Option ['i'] [] (GetOpt.ReqArg Include "path")
        "add to module include path"
    , GetOpt.Option ['v'] [] (GetOpt.NoArg Verbose)
        "print added and removed modules on stderr"
    ]

usage :: String -> IO a
usage msg = do
    name <- Environment.getProgName
    putStr $ GetOpt.usageInfo (msg ++ "\n" ++ name ++ " Module.hs <Module.hs")
        options
    Exit.exitFailure

parseArgs :: [String] -> IO (String, (Bool, Bool, [FilePath]))
parseArgs args = case GetOpt.getOpt GetOpt.Permute options args of
    (flags, [modulePath], []) -> return (modulePath, parse flags)
    (_, [], errs) -> usage $ concat errs
    _ -> usage "too many args"
    where
    parse flags =
        ( Verbose `elem` flags
        , Debug `elem` flags
        , "." : [p | Include p <- flags]
        )
    -- Includes always have the current directory first.
