{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
module Config_test where
import qualified Data.Text as Text
import EL.Test.Global
import qualified EL.Test.Testing as Testing
import qualified Language.Haskell.Exts as Haskell

import qualified Config
import qualified FixImports
import qualified Types


test_parse = do
    let f = parseConfig
    equal (Config.importPriority $
            f ["import-order-first: A", "import-order-last: B"]) $
        Config.Priority ["A"] ["B"]

test_pickModule = do
    let f config modulePath candidates = Config.pickModule
            (Config.modulePriority (parseConfig config))
            modulePath candidates
    equal (f [] "X.hs" []) Nothing
    let localAB = [(Nothing, "A.M"), (Nothing, "B.M")]
    equal (f [] "X.hs" localAB) $
        Just (Nothing, "A.M")
    equal (f ["prio-module-high: B.M"] "X.hs" localAB) $
        Just (Nothing, "B.M")
    -- Has to be an exact match.
    equal (f ["prio-module-high: B"] "X.hs" localAB) $
        Just (Nothing, "A.M")

    -- Local modules take precedence.
    equal (f [] "A/B.hs" [(Nothing, "B.M"), (Just "pkg", "B.M")]) $
        Just (Nothing, "B.M")
    equal (f [] "A/B/C.hs" [(Nothing, "A.B.M"), (Just "pkg", "B.M")]) $
        Just (Nothing, "A.B.M")
    -- Closer local modules precede further ones.
    equal (f [] "A/B/C.hs" [(Nothing, "A.B.M"), (Nothing, "A.M")]) $
        Just (Nothing, "A.B.M")
    -- Prefer fewer dots.
    equal (f [] "X.hs" [(Just "p1", "A.B.M"), (Just "p2", "Z.M")]) $
        Just (Just "p2", "Z.M")

test_formatGroups = do
    let f config imports = lines $ Config.formatGroups
            (Config.importPriority (parseConfig config))
            (Testing.expectRight (parse (unlines imports)))
    equal (f [] []) []
    equal (f [] ["import Z", "import A"])
        [ "import A"
        , "import Z"
        ]
    equal (f ["import-order-first: Z"] ["import Z", "import A"])
        [ "import Z"
        , "import A"
        ]
    equal (f ["import-order-last: A"] ["import Z", "import A"])
        [ "import Z"
        , "import A"
        ]

    -- Exact match.
    equal (f ["import-order-first: Z"] ["import Z.A", "import A"])
        [ "import A"
        , "import Z.A"
        ]
    -- Unless it's a prefix match.
    equal (f ["import-order-first: Z."] ["import Z.A", "import A"])
        [ "import Z.A"
        , "import A"
        ]


-- * util

importLine :: Types.ImportDecl -> Types.ImportLine
importLine decl = Types.ImportLine
    { importDecl = decl
    , importComments = []
    , importSource = Types.Local
    }

parse :: String -> Either String [Types.ImportLine]
parse source = case FixImports.parse [] "" source of
    Haskell.ParseFailed srcloc err ->
        Left $ Haskell.prettyPrint srcloc ++ ": " ++ err
    Haskell.ParseOk (mod, cmts) -> Right $ map (importLine . fst) imports
        where
        (_newImports, _unusedImports, imports, _range) =
            FixImports.importInfo mod cmts

parseConfig :: [Text.Text] -> Config.Config
parseConfig lines
    | null errs = config
    | otherwise = error $ "parsing " <> show lines  <> ": " <> unlines errs
    where (config, errs) = Config.parse (Text.unlines lines)