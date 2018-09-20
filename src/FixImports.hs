{- | Automatically fix the import list in a haskell module.

    This only really works for qualified names.  The process is as follows:

    - Parse the entire file and extract the Qualification of qualified names
    like @A.b@, which is simple @A@.

    - Combine this with the modules imported to decide which imports can be
    removed and which ones must be added.

    - For added imports, guess the complete import path implied by the
    Qualification.  This requires some heuristics:

        - Check local modules first.  Start in the current module's directory
        and then try from the current directory, descending recursively.

        - If no local modules are found, check the package database.  There is
        a system of package priorities so that @List@ will yield @Data.List@
        from @base@ rather than @List@ from @haskell98@.  After that, shorter
        matches are prioritized so @System.Process@ is chosen over
        @System.Posix.Process@.

        - If the module is not found at all, an error is printed on stderr and
        the unchanged file on stdout.

        - Of course the heuristics may get the wrong module, but existing
        imports are left alone so you can edit them by hand.

    - Then imports are sorted, grouped, and a new module is written to stdout
    with the new import block replacing the old one.

        - The default import formatting separates package imports from local
        imports, and groups them by their toplevel module name (before the
        first dot).  Small groups are combined.  They go in alphabetical order
        by default, but a per-project order may be defined.
-}
{-# LANGUAGE OverloadedStrings #-}
module FixImports where
import Prelude hiding (mod)
import Control.Applicative ((<$>))
import Control.Monad
import qualified Data.Bifunctor as Bifunctor
import qualified Data.Char as Char
import qualified Data.Either as Either
import qualified Data.Generics.Uniplate.Data as Uniplate
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Time.Clock as Clock

import qualified Language.Haskell.Exts as Haskell
import qualified Language.Haskell.Exts.Extension as Extension
import qualified Language.Preprocessor.Cpphs as Cpphs

import qualified Numeric
import qualified System.Directory as Directory
import qualified System.FilePath as FilePath
import System.FilePath ((</>))
import qualified System.Process as Process

import qualified Config
import qualified Index
import qualified Types
import qualified Util


data Result = Result {
    resultText :: String
    , resultAdded :: Set.Set Types.ModuleName
    , resultRemoved :: Set.Set Types.ModuleName
    , resultMetrics :: [Metric]
    } deriving (Show)

type Metric = (Clock.UTCTime, Text)

addMetrics :: [Metric] -> Result -> Result
addMetrics ms result = result { resultMetrics = ms ++ resultMetrics result }

fixModule :: Config.Config -> FilePath -> String -> IO (Either String Result)
fixModule config modulePath source = do
    mStart <- metric "start"
    processedSource <- cppModule modulePath source
    mCpp <- metric "cpp"
    case parse (Config._language config) modulePath processedSource of
        Haskell.ParseFailed srcloc err ->
            return $ Left $ Haskell.prettyPrint srcloc ++ ": " ++ err
        Haskell.ParseOk (mod, cmts) -> do
            mParse <- mod `seq` cmts `seq` metric "parse"
            fmap (addMetrics [mStart, mCpp, mParse]) <$>
                fixImports config modulePath mod cmts source

parse :: [Extension.Extension] -> FilePath -> String
    -> Haskell.ParseResult
        (Haskell.Module Haskell.SrcSpanInfo, [Haskell.Comment])
parse extensions modulePath =
    Haskell.parseFileContentsWithComments $ Haskell.defaultParseMode
        { Haskell.parseFilename = modulePath
        , Haskell.extensions = extensions ++ defaultExtensions
        -- The meaning of Nothing is undocumented, but I think it means
        -- to not check for fixity ambiguity at all, which is what I want.
        , Haskell.fixities = Nothing
        }
    where
    defaultExtensions = map Extension.EnableExtension $
        Extension.toExtensionList Extension.Haskell2010 []
        -- GHC has this extension enabled by default, and it's easy
        -- to wind up with code that relies on it:
        -- http://www.haskell.org/ghc/docs/7.6.3/html/users_guide/bugs-and-infelicities.html#infelicities-syntax
        ++ [Extension.NondecreasingIndentation]

-- | The parse function takes a CPP extension, but doesn't actually pay any
-- attention to it, so I have to run CPP myself.  The imports are fixed
-- post-CPP so if you put CPP in the imports block it will be stripped out.
-- It seems hard to fix imports inside CPP.
cppModule :: FilePath -> String -> IO String
cppModule filename s = Cpphs.runCpphs options filename s
    where
    options = Cpphs.defaultCpphsOptions { Cpphs.boolopts = boolOpts }
    boolOpts = Cpphs.defaultBoolOptions
        { Cpphs.macros = True
        , Cpphs.locations = False
        , Cpphs.hashline = False
        , Cpphs.pragma = False
        , Cpphs.stripEol = True
        , Cpphs.stripC89 = True
        , Cpphs.lang = True -- lex input as haskell code
        , Cpphs.ansi = True
        , Cpphs.layout = True
        , Cpphs.literate = False -- untested with literate code
        , Cpphs.warnings = False
        }

-- | Take a parsed module along with its unparsed text.  Generate a new import
-- block with proper spacing, formatting, and comments.  Then snip out the
-- import block on the import file, and replace it.
fixImports :: Config.Config -> FilePath -> Types.Module
    -> [Haskell.Comment] -> String -> IO (Either String Result)
fixImports config modulePath mod cmts source = do
    -- Don't bother loading the index if I'm not going to use it.
    -- TODO actually, only load it if I don't find local imports
    -- I guess Data.Binary's laziness will serve me there
    mProcess <- newImports `seq` unusedImports `seq` imports `seq` range
        `seq` metric "process"
    index <- if Set.null newImports then return Index.empty else Index.load
    mLoad <- metric "load-index"

    mbNew <- mapM (mkImportLine config modulePath index) (Set.toList newImports)
    mNewImports <- metric "find-new-imports"
    mbExisting <- mapM (findImport (Config._includes config)) imports
    mExistingImports <- metric "find-existing-imports"
    let existing = map (Types.importDeclModule . fst) imports
    let (notFound, importLines) = Either.partitionEithers $
            zipWith mkError
                (map toModule (Set.toList newImports) ++ existing)
                (mbNew ++ mbExisting)
        mkError _ (Just imp) = Right imp
        mkError mod Nothing = Left mod
    let formattedImports =
            Config.formatGroups (Config._order config) importLines
    return $ case notFound of
        _ : _ -> Left $ "modules not found: "
            ++ Util.join ", " (map Types.moduleName notFound)
        [] -> Right $ Result
            { resultText = substituteImports formattedImports range source
            , resultAdded = Set.fromList $
                map (Types.importDeclModule . Types.importDecl) $
                Maybe.catMaybes mbNew
            , resultRemoved = unusedImports
            , resultMetrics = [mProcess, mLoad, mNewImports, mExistingImports]
            }
    where
    (newImports, unusedImports, imports, range) = importInfo mod cmts
    toModule (Types.Qualification name) = Types.ModuleName name

-- | Clip out the range from the given text and replace it with the given
-- lines.
substituteImports :: String -> (Int, Int) -> String -> String
substituteImports imports (start, end) source =
    unlines pre ++ imports ++ unlines post
    where
    (pre, within) = splitAt start (lines source)
    (_, post) = splitAt (end-start) within

-- * find new imports

-- | Make a new ImportLine from a ModuleName.
mkImportLine :: Config.Config -> FilePath -> Index.Index -> Types.Qualification
    -> IO (Maybe Types.ImportLine)
mkImportLine config modulePath index qual@(Types.Qualification name) = do
    found <- findModule config index modulePath qual
    return $ case found of
        Nothing -> Nothing
        Just (mod, local) -> Just (Types.ImportLine (mkImport mod) [] local)
    where
    mkImport (Types.ModuleName mod) = Haskell.ImportDecl
        { Haskell.importAnn = empty
        , Haskell.importModule = Haskell.ModuleName empty mod
        , Haskell.importQualified = True
        , Haskell.importSrc = False
        , Haskell.importSafe = False
        , Haskell.importPkg = Nothing
        , Haskell.importAs = importAs mod
        , Haskell.importSpecs = Nothing
        }
    importAs mod
        | name == mod = Nothing
        | otherwise = Just $ Haskell.ModuleName empty name
    empty = Haskell.noInfoSpan (Haskell.SrcSpan "" 0 0 0 0)

-- | Find the qualification and its ModuleName and True if it was a local
-- import.  Nothing if it wasn't found at all.
findModule :: Config.Config -> Index.Index -> FilePath
    -- ^ Path to the module being fixed.
    -> Types.Qualification -> IO (Maybe (Types.ModuleName, Types.Source))
findModule config index modulePath qual = do
    found <- findLocalModules (Config._includes config) qual
    let local = [(Nothing, Types.pathToModule fn) | fn <- found]
        package = map (Bifunctor.first Just) $ Map.findWithDefault [] qual index
    Config.debug config $ "findModule " <> showt qual <> " from "
        <> showt modulePath <> ": local " <> showt found
        <> "\npackage: " <> showt package
    let prio = Config._modulePriority config
    return $ case Config.pickModule prio modulePath (local++package) of
        Just (package, mod) -> Just
            (mod, if package == Nothing then Types.Local else Types.Package)
        Nothing -> Nothing

-- | Given A.B, look for A/B.hs, */A/B.hs, */*/A/B.hs, etc. in each of the
-- include paths.
findLocalModules :: [FilePath] -> Types.Qualification -> IO [FilePath]
findLocalModules includes (Types.Qualification name) = do
    concat <$> forM includes (\dir -> map (stripDir dir) <$>
        findFiles 4 (Types.moduleToPath (Types.ModuleName name)) dir)

stripDir :: FilePath -> FilePath -> FilePath
stripDir dir path
    | dir == "." = path
    | otherwise = dropWhile (=='/') $ drop (length dir) path

findFiles :: Int -- ^ Descend into subdirectories this many times.
    -> FilePath -- ^ Find files with this suffix.  Can contain slashes.
    -> FilePath -- ^ Start from this directory.  Return [] if it doesn't exist.
    -> IO [FilePath]
findFiles depth file dir = do
    fns <- Maybe.fromMaybe [] <$> Util.catchENOENT (Util.listDir dir)
    (subdirs, fns) <- Util.partitionM Directory.doesDirectoryExist fns
    subfns <- if depth > 0
        then concat <$> mapM (findFiles (depth-1) file)
            (filter isModuleDir subdirs)
        else return []
    return $ filter sameSuffix fns ++ subfns
    where
    isModuleDir = all Char.isUpper . take 1 . FilePath.takeFileName
    sameSuffix fn = fn == file || ('/' : file) `List.isSuffixOf` fn


-- * figure out existing imports

-- | Make an existing import into an ImportLine by finding out if it's a local
-- module or a package module.
findImport :: [FilePath] -> (Types.ImportDecl, [Types.Comment])
    -> IO (Maybe Types.ImportLine)
findImport includes (imp, cmts) = do
    found <- findModuleName includes (Types.importDeclModule imp)
    return $ case found of
        Nothing -> Nothing
        Just source -> Just $ Types.ImportLine imp cmts source

-- | True if it was found in a local directory, False if it was found in the
-- ghc package db, and Nothing if it wasn't found at all.
findModuleName :: [FilePath] -> Types.ModuleName -> IO (Maybe Types.Source)
findModuleName includes mod =
    Util.ifM (isLocalModule mod ("" : includes)) (return (Just Types.Local)) $
        Util.ifM (isPackageModule mod) (return (Just Types.Package))
            (return Nothing)

isLocalModule :: Types.ModuleName -> [FilePath] -> IO Bool
isLocalModule mod =
    Util.anyM (Directory.doesFileExist . (</> Types.moduleToPath mod))

isPackageModule :: Types.ModuleName -> IO Bool
isPackageModule (Types.ModuleName name) = do
    output <- Process.readProcess "ghc-pkg"
        ["--simple-output", "find-module", name] ""
    return $ not (null output)

-- * util

importInfo :: Types.Module -> [Haskell.Comment]
    -> (Set.Set Types.Qualification, Set.Set Types.ModuleName,
        [(Types.ImportDecl, [Types.Comment])], (Int, Int))
    -- ^ (missingImports, unusedImports, unchangedImports, rangeOfImportBlock).
importInfo mod cmts = (missing, unused, declCmts, range)
    where
    unused = Set.difference (Set.fromList modules)
        (Set.fromList (map (Types.importDeclModule . fst) declCmts))
    missing = Set.difference used imported
    -- If the Prelude isn't explicitly imported, it's implicitly imported, so
    -- if I see Prelude.x it doesn't mean to add an import.
    imported = Set.fromList $ prelude : qualifiedImports

    -- Get from the qualified import name back to the actual module name so
    -- I can return that.
    modules = map Types.importDeclModule imports
    qualifiedImports = map Types.importDeclQualification imports
    used = Set.fromList (moduleQNames mod)
    imports = moduleImportDecls mod
    declCmts =
        [ imp
        | imp@(decl, _) <- associateComments imports
            (filterImportCmts range cmts)
        , keepImport decl
        ]
    -- Keep unqualified imports, but only keep qualified ones if they are used.
    -- Prelude is considered always used if it appears, because removing it
    -- changes import behavour.
    keepImport decl =
        Set.member (Types.importDeclQualification decl)
            (Set.insert prelude used)
        || not (Haskell.importQualified decl)
    prelude = Types.Qualification "Prelude"
    range = importRange mod

filterImportCmts :: (Int, Int) -> [Haskell.Comment] -> [Haskell.Comment]
filterImportCmts (start, end) = filter inRange
    where
    inRange (Haskell.Comment _ src _) = start <= s && s < end
        where s = Haskell.srcSpanStartLine src - 1 -- spans are 1-based


-- | Pair ImportDecls up with the comments that apply to them.  Comments
-- below the last import are dropped, but there shouldn't be any of those
-- because they should have been omitted from the comment block.
--
-- Spaces between comments above an import will be lost, and multiple comments
-- to the right of an import (e.g. commenting a complicated import list) will
-- probably be messed up.  TODO Fix it if it becomes a problem.
associateComments :: [Types.ImportDecl] -> [Haskell.Comment]
    -> [(Types.ImportDecl, [Types.Comment])]
associateComments imports cmts = snd $ List.mapAccumL associate cmts imports
    where
    associate cmts imp = (after, (imp, associated))
        where
        associated = map (Types.Comment Types.CmtAbove . cmtText) above
            ++ map (Types.Comment Types.CmtRight . cmtText) right
        -- cmts that end before the import beginning are above it
        (above, rest) = List.span ((< start impSpan) . end . cmtSpan) cmts
        -- remaining cmts that start before or at the import's end are right
        -- of it
        (right, after) = List.span ((<= end impSpan) . start . cmtSpan) rest
        impSpan = Haskell.srcInfoSpan (Haskell.importAnn imp)
    cmtSpan (Haskell.Comment _ span _) = span
    cmtText (Haskell.Comment True _ s) = "{-" ++ s ++ "-}"
    cmtText (Haskell.Comment False _ s) = "--" ++ s
    start = Haskell.srcSpanStartLine
    end = Haskell.srcSpanEndLine

moduleImportDecls :: Types.Module -> [Types.ImportDecl]
moduleImportDecls (Haskell.Module _ _ _ imports _) = imports
moduleImportDecls _ = []

-- | Return half-open line range of import block, starting from (0 based) line
-- of first import to the line after the last one.
importRange :: Types.Module -> (Int, Int)
importRange mod = case mod of
        -- Haskell.Module _ mb_head _ imports _ ->
        --     let start = headEnd mb_head
        --     in (start, max start (importsEnd imports))
        Haskell.Module _ Nothing _ imports _ ->
            (importsStart imports, importsEnd imports)
        Haskell.Module _ (Just modHead) _ imports _ ->
            let start = headEnd modHead
            in (start, max start (importsEnd imports))
        _ -> (0, 0)
    where
    -- The parser counts lies from 1, but I return a half-open range from 0.
    -- So I don't need to +1 the last line of the head, and since the range
    -- is half-open I don't need to -1 the last line of the imports.
    headEnd (Haskell.ModuleHead src _ _ _) = endOf src
    importsStart [] = 0
    importsStart (importDecl : _) =
        startOf (Haskell.importAnn importDecl) - 1
    importsEnd [] = 0
    importsEnd imports = (endOf . Haskell.importAnn . last) imports

    startOf = Haskell.srcSpanStartLine . Haskell.srcInfoSpan
    endOf = Haskell.srcSpanEndLine . Haskell.srcInfoSpan

-- | Uniplate is rad.
moduleQNames :: Types.Module -> [Types.Qualification]
moduleQNames mod =
    [Types.moduleToQualification m
    |  Haskell.Qual _ m _ <- Uniplate.universeBi mod
    ]

-- * metrics

metric :: Text -> IO Metric
metric name = flip (,) name <$> Clock.getCurrentTime

showMetrics :: [Metric] -> Text
showMetrics = Text.unlines . format -- . filter ((>0.01) . snd)
    . map diff . Util.zipPrev . Util.sortOn fst
    where
    format metricDurs =
        map (format1 total) (metricDurs ++ [("total", total)])
        where total = sum (map snd metricDurs)
    format1 total (metric, dur) = Text.unwords
        [ justifyR 8 (showDuration dur)
        , justifyR 3 (percent (realToFrac dur / realToFrac total))
        , "-", metric
        ]
    diff ((prev, _), (cur, metric)) =
        (metric, cur `Clock.diffUTCTime` prev)

percent :: Double -> Text
percent = (<>"%") . showt . round . (*100)

showDuration :: Clock.NominalDiffTime -> Text
showDuration = Text.pack . ($"s") . Numeric.showFFloat (Just 2) . realToFrac

justifyR :: Int -> Text -> Text
justifyR width = Text.justifyRight width ' '

showt :: Show a => a -> Text
showt = Text.pack . show
