{-
 - Copyright 2011-2013 Per Magnus Therning
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -     http://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}

module Util.Misc where

-- {{{1 imports
import qualified PkgDB as DB

import Codec.Archive.Tar as Tar
import Codec.Compression.GZip as GZip
import Control.Exception (onException)
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Data.Either
import Data.Version
import Distribution.Compiler
import Distribution.Package as P
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import Distribution.System
import Distribution.Text
import Distribution.Verbosity
import Distribution.Version
import Options.Applicative
import Options.Applicative.Types
import Safe (lastMay)
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Posix.Files
import System.Process
import System.Unix.Directory
import Text.ParserCombinators.ReadP hiding (many)
import qualified Data.ByteString.Lazy.Char8 as BS

-- {{{1 dependency
depName (Dependency (PackageName n) _) = n
depVersionRange (Dependency _ vr) = vr

-- {{{ print functions
printUnSat (n, ds) = do
    putStrLn $ "Failed to satisfy the following dependencies for " ++ n ++ ":"
    mapM_ (putStrLn . ("  " ++) . display) ds

printBrksOth  ((n, v), brks) = do
    putStrLn $ "Adding " ++ n ++ " " ++ display v ++ " would break:"
    mapM_ (\ (bN, Just bD) -> putStrLn $ "  " ++ bN ++ " : " ++ display bD) brks

-- {{{1 program variables
progName = "cblrepo"
dbName = progName ++ ".db"

ghcDefVersion = Version [7, 8, 3] []
ghcVersionDep :: Version -> Int -> String
ghcVersionDep ghcVer ghcRel = "ghc=" ++ display ghcVer ++ "-" ++ show ghcRel

indexUrl = "http://hackage.haskell.org/packages/index.tar.gz"
indexFileName = "index.tar.gz"

-- {{{1 command line parser helpers
readerGhcVersion :: ReadM Version
readerGhcVersion = do
    arg <- readerAsk
    case lastMay $ readP_to_S parseVersion arg of
        Just (v, "") -> return v
        _ -> fail $ "cannot parse value `" ++ arg ++ "`"

splitOnElem :: Eq a => a -> [a] -> [[a]]
splitOnElem e l =
    let p@(a, b) = break (== e) l
    in case p of
        (_, []) -> [a]
        (_, _) -> a : splitOnElem e (tail b)

strPairArg :: Char -> ReadM (String, String)
strPairArg c = do
    s <- readerAsk
    case splitOnElem c s of
        [a, b] -> return (a, b)
        _ -> error $ "Failed to parse pair: " ++ s

strTripleArg :: Monad m => Char -> String -> m (String, String, String)
strTripleArg c s =
    case splitOnElem c s of
        [a, b, c] -> return (a, b, c)
        _ -> error $ "Failed to parse triple: " ++ s

ghcPkgArgReader :: ReadM (String, Version)
ghcPkgArgReader = do
    (pkgName, verStr) <- strPairArg ','
    case simpleParse verStr of
        Nothing -> fail $ "Failed to parse version in " ++ pkgName ++ "," ++ verStr
        Just v -> return (pkgName, v)

distroPkgArgReader :: ReadM (String, Version, String)
distroPkgArgReader = do
    s <- readerAsk
    (pkgName, verStr, revStr) <- strTripleArg ',' s
    case simpleParse verStr of
        Nothing -> fail $ "Failed to parse version in " ++ s
        Just v -> return (pkgName, v, revStr)

readFlag :: ReadP (FlagName, Bool)
readFlag = readNegFlag <++ readPosFlag
    where
        readNegFlag = do
            char '-'
            n <- many (satisfy (/= ','))
            return (FlagName n, False)

        readPosFlag = do
            n0 <- get
            n <- many (satisfy (/= ','))
            return (FlagName (n0 : n), True)

strCblFileArg :: ReadM (FilePath, FlagAssignment)
strCblFileArg = let
        readWithFlags = do
            fn <- many $ satisfy (/= ':')
            char ':'
            fas <- sepBy readFlag (char ',')
            return (fn, fas)

        readWithoutFlags = do
            fn <- many $ satisfy (/= ':')
            return (fn, [])

    in do
        s <-readerAsk
        case lastMay (readP_to_S (readWithFlags <++ readWithoutFlags) s) of
            Just (r, "") -> return r
            _ -> fail $ "Cannot parse '" ++ s ++ "' as FILE[:FLAG,-FLAG,..]"

strCblPkgArg :: ReadM (String, Version, FlagAssignment)
strCblPkgArg = let
        readPkgNVersion :: ReadP (String, Version)
        readPkgNVersion = do
            n <- many (satisfy (/= ','))
            char ','
            v <- parseVersion
            return (n, v)

        readWithFlags = do
            (n, v) <- readPkgNVersion
            char ':'
            fas <- sepBy readFlag (char ',')
            return (n, v, fas)

        readWithoutFlags = do
            (n, v) <- readPkgNVersion
            return (n, v, [])

    in do
        s <- readerAsk
        case lastMay (readP_to_S (readWithFlags <++ readWithoutFlags) s) of
            Just (r, "") -> return r
            _ -> fail $ "Cannot parse: " ++ s

-- Helper for grabbing things out of the options
optGet :: MonadReader o m => (o -> s) -> m s
optGet f = liftM f ask

-- {{{1 command line argument type
data Cmds
    = CmdAdd
        { patchDir :: FilePath, ghcVer :: Version, cmdAddGhcPkgs :: [(String, Version)]
        , cmdAddDistroPkgs :: [(String, Version, String)], cmdAddFileCbls :: [(FilePath, FlagAssignment)]
        , cmdAddCbls :: [(String, Version, FlagAssignment)] }
    | CmdBuildPkgs { pkgs :: [String] }
    | CmdBumpPkgs { inclusive :: Bool, pkgs :: [String] }
    | CmdSync { unused :: Bool }
    | CmdVersions { latest :: Bool, pkgs :: [String] }
    | CmdListPkgs
        { listGhc :: Bool, listDistro :: Bool, noListRepo :: Bool
        , hackageFmt :: Bool, pkgs :: [String] }
    | CmdUpdates { idxStyle :: Bool }
    | CmdUrls { pkgVers :: [(String, String)] }
    | CmdPkgBuild { ghcVer :: Version, ghcRel :: Int, patchDir :: FilePath, pkgs :: [String] }
    | CmdConvertDb { inDbFile :: FilePath, outDbFile :: FilePath }
    | CmdRemovePkg { pkgs :: [String] }
    deriving (Show)

data Opts = Opts
    { appDir :: FilePath
    , dbFile :: FilePath
    , dryRun :: Bool
    , optsCmd :: Cmds
    } deriving (Show)

-- {{{1 getFromURL
getFromURL url fn = do
    (ec, _, er) <- readProcessWithExitCode "curl" ["-f", "-L", "-o", fn, url] ""
    case ec of
        ExitSuccess -> return ()
        ExitFailure _ -> do
            hPutStrLn stderr ("Failed downloading " ++ url)
            hPutStrLn stderr er
            exitFailure

-- {{{1 applyPatchIfExist
applyPatch origFilename patchFilename = do
    (ec, _, _) <- liftIO $ readProcessWithExitCode "patch" [origFilename, patchFilename] ""
    case ec of
        ExitSuccess -> return ()
        ExitFailure _ ->
            throwError ("Failed patching " ++ origFilename ++ " with " ++ patchFilename)

applyPatchIfExist origFilename patchFilename =
    liftIO (fileExist patchFilename) >>= flip when (applyPatch origFilename patchFilename)

-- {{{1 index functions
readIndexFile indexLocation = exitOnException
    "Cannot open index file, have you run the 'sync' command?"
    (BS.readFile $ indexLocation </> indexFileName)

-- {{{1 package descriptions
-- {{{2 readCabal
data LocType = Idx | File

-- | Read in a Cabal file.
readCabalFromFile = readCabal
readCabalFromIdx ad pd (p, v) = readCabal ad pd (p ++ "," ++ v')
    where v' = display v

readCabal :: FilePath -> FilePath -> String -> FilePath -> ErrorT String IO GenericPackageDescription
readCabal appDir patchDir loc tmpDir = let
        locType
            | ',' `elem` loc = Idx
            | otherwise = File

        copyCabal tmpDir loc = copyFile loc fn >> return fn
            where fn = tmpDir </> takeFileName loc

        extractCabal tmpDir loc = let
                (p, _: v) = span (/= ',') loc
                path = p </> v </> p ++ ".cabal"
                pkgStr = p ++ " " ++ v
                fn = tmpDir </> (p ++ ".cabal")

                esFindEntry p (Next e es) = if p == entryPath e
                    then Just e
                    else esFindEntry p es
                esFindEntry _ _ = Nothing

                eGetContent e = let
                        ec = entryContent e
                    in case ec of
                        NormalFile c _ -> Just $ BS.unpack c
                        _ -> Nothing

            in do
                es <- liftM (Tar.read . GZip.decompress) (liftIO $ readIndexFile appDir)
                e <- maybe (throwError $ "No entry for " ++ pkgStr)
                    return
                    (esFindEntry path es)
                cbl <- maybe (throwError $ "Failed to extract contents for " ++ pkgStr)
                    return
                    (eGetContent e)
                liftIO $ writeFile fn cbl
                return fn

        extractName fn = liftM name $ readPackageDescription silent fn
            where
                packageName (PackageName s) = s
                name = packageName . pkgName . package . packageDescription

    in do
        cblFn <- case locType of
            File -> liftIO $ copyCabal tmpDir loc
            Idx -> extractCabal tmpDir loc
        pn <- liftIO $ extractName cblFn
        let patchFn = patchDir </> pn <.> "cabal"
        applyPatchIfExist cblFn patchFn
        liftIO $ readPackageDescription silent cblFn

-- {{{2 finalising
finalizePkg ghcVersion db fa gpd = let
        n = ((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription) gpd
    in finalizePackageDescription
        fa
        (checkAgainstDb db n)
        (Platform X86_64 buildOS) -- platform
        (CompilerId GHC ghcVersion)  -- compiler version
        [] -- no additional constraints
        gpd

checkAgainstDb db name dep = let
        dN = depName dep
        dVR = depVersionRange dep
    in (dN == name) ||
            (case DB.lookupPkg db dN of
                Nothing -> False
                Just (DB.CP _ p) -> withinRange (DB.version p) dVR)

-- {{{1 Command type
type Command a = ReaderT Opts IO a

runCommand cmds func = runReaderT func cmds

-- {{{1 ErrorT
withTempDirErrT fp func = let
        reWrapErrT (Left e) = throwError e
        reWrapErrT (Right v) = return v
    in do
        r <- liftIO $ withTemporaryDirectory fp (runErrorT . func)
        reWrapErrT r

exitOnErrors vs = let
        es = lefts vs
    in
        if not $ null $ lefts vs
            then liftIO $ mapM_ (hPutStrLn stderr) es >> exitFailure
            else return (rights vs)

exitOnException msg a = onException a $ hPutStrLn stderr msg >> exitFailure
