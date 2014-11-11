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

module Updates where

import PkgDB
import Util.Misc
import Util.HackageIndex

import Codec.Archive.Tar as Tar
import Codec.Compression.GZip as GZip
import Control.Arrow
import Control.Monad
import Control.Monad.Reader
import Data.Maybe
import Distribution.Text
import Distribution.Version
import System.FilePath

updates :: Command ()
updates = do
    db <- optGet dbFile >>= liftIO . readDb
    aD <- optGet appDir
    aCS <- optGet $ idxStyle .optsCmd
    entries <- liftIO $ liftM (Tar.read . GZip.decompress) (readIndexFile aD)
    let nonBasePkgs = filter (not . isBasePkg) db
    let pkgsNVers = map (pkgName &&& pkgVersion) nonBasePkgs
    let availPkgs = catMaybes $ eMap extractPkgVer entries
    let outdated = filter
            (\ (p, v) -> maybe False (> v) (latestVer p availPkgs))
            pkgsNVers
    let printer = if aCS
            then printOutdatedIdx
            else printOutdated
    liftIO $ mapM_ (`printer` availPkgs) outdated

type PkgVer = (String, Version)

extractPkgVer :: Entry -> Maybe PkgVer
extractPkgVer e = let
        ep = entryPath e
        isCabal = '/' `elem` ep
        (pkg:ver':_) = map dropTrailingPathSeparator $ splitPath ep
        ver = simpleParse ver'
    in if isCabal && isJust ver
        then Just (pkg, fromJust ver)
        else Nothing

latestVer p pvs = let
        vs = map snd $ filter ((== p) . fst) pvs
    in if null vs
        then Nothing
        else Just $ maximum vs

eMap _ Done = []
eMap f (Next e es) = f e:eMap f es
eMap _ (Fail _) = error "Failure to read index"

printOutdated (p, v) avail = let
        l = fromJust $ latestVer p avail
    in
        putStrLn $ p ++ ": " ++ display v ++ " (" ++ display l ++ ")"

printOutdatedIdx (p, _) avail = let
        l = fromJust $ latestVer p avail
    in
        putStrLn $ p ++ "," ++ display l
