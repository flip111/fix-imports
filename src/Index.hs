-- | Maintain the index from Qualification to the full module from the package
-- db that this Qualification probably intends.
module Index where
import Prelude hiding (mod)
import Control.Applicative ((<$>))
import Control.Monad
import qualified Data.Either as Either
import qualified Data.List as List
import qualified Data.Map as Map

import qualified System.IO as IO
import qualified System.Process as Process

import qualified Types
import qualified Util


-- | Map from tails of the each module in the package db to its module name.
-- So @List@ and @Data.List@ will map to @Data.List@.  Modules from a set
-- of core packages, like base and containers, will take priority, so even if
-- there's a package with @Some.Obscure.List@, @List@ will still map to
-- @Data.List@.
type Index = Map.Map Types.Qualification [(Package, Types.ModuleName)]

-- | Package name without the version.
type Package = String

empty :: Index
empty = Map.empty

loadIndex :: IO Index
loadIndex = buildIndex -- TODO load cache?

buildIndex :: IO Index
buildIndex = do
    (errors, index) <- parseDump <$> Process.readProcess "ghc-pkg"
        ["field", "*", "name,exposed,exposed-modules"] ""
    unless (null errors) $
        IO.hPutStrLn IO.stderr $ "errors parsing ghc-pkg output: "
            ++ List.intercalate ", " errors
    return index

parseDump :: String -> ([String], Index)
parseDump text = (errors, index)
    where
    index = Map.fromListWith (++)
        [(qual, [(package, mod)]) | (package, modules) <- packages,
            mod <- modules, qual <- moduleQualifications mod]
    (errors, packages) = Either.partitionEithers $
        extractExposed (parseSections text)
    extractExposed [] = []
    extractExposed (("name", [name]) : ("exposed", [exposed])
            : ("exposed-modules", modules) : rest)
        | exposed /= "True" = extractExposed rest
        | otherwise = Right (name, map Types.ModuleName modules)
            : extractExposed rest
    extractExposed ((tag, _) : rest) =
        Left ("unexpected tag: " ++ tag) : extractExposed rest

-- | Take a module name to all its possible qualifications, i.e. its list
-- of suffixes.
moduleQualifications :: Types.ModuleName -> [Types.Qualification]
moduleQualifications = map (Types.Qualification . Util.join ".")
    . filter (not . null) . List.tails . Util.split "." . Types.moduleName

parseSections :: String -> [(String, [String])] -- ^ [(section_name, words)]
parseSections = List.unfoldr parseSection . lines

parseSection :: [String] -> Maybe ((String, [String]), [String])
parseSection [] = Nothing
parseSection (x:xs) = Just ((tag, concatMap words (drop 1 rest : pre)), post)
    where
    (tag, rest) = break (==':') x
    (pre, post) = span ((==" ") . take 1) xs

{-
-- * test

t0 = makePairs prio $ map (\(p, ms) -> (p, map Types.ModuleName ms))
    [ ("base", ["Data.List", "Foo.Bar.List"])
    , ("haskell98", ["List"])
    , ("containers", ["Box.List"])
    ]
    -- Not containers Box.List because containers is lower prio.
    -- Not haskell98 List because haskell98 is lowest prio, even though that's
    -- the shortest match.
    -- Not Foo.Bar.List because Data.List is a shorter match.

t1 = Map.lookup (Types.Qualification "List") (Map.fromList t0)
t10 = List.unfoldr parseSection ["hi: there fred", "  foo", "next: section"]
tdump =
    [ "name: base", "exposed: True", "exposed-modules: Data.List Data.Map"
    , "name: mtl", "exposed: True", "exposed-modules: Monad.B.List"
    ]
-}
