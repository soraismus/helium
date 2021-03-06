{-| Module      :  Main
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable
-}
module Main where

import Helium.Main.Compile(compile)
import Helium.Parser.Parser(parseOnlyImports)
import Control.Monad
import System.FilePath(joinPath)
import Data.List(nub, elemIndex, isSuffixOf, isPrefixOf, intercalate)
import Data.Maybe(fromJust)
import Lvm.Path(explodePath,getLvmPath)
import System.Directory(doesFileExist, getModificationTime,
                        getPermissions, Permissions(writable))
import Helium.Main.Args
import Helium.Main.CompileUtils
import Data.IORef
import Paths_helium
        
-- Prelude will be treated specially
prelude :: String
prelude = "Prelude.hs"

-- Order matters
coreLibs :: [String]
coreLibs = ["LvmLang", "LvmIO", "LvmException", "HeliumLang", "PreludePrim"]

main :: IO ()
main = do
    args                     <- getArgs
    (options, Just fullName) <- processHeliumArgs args -- Can't fail, because processHeliumArgs checks it.
    
    lvmPathFromOptionsOrEnv <- case lvmPathFromOptions options of 
        Nothing -> getLvmPath
        Just s  -> return (explodePath s)
    
    baseLibs <- case basePathFromOptions options of 
        Nothing -> getDataFileName $ 
                     if overloadingFromOptions options 
                     then "lib" 
                     else joinPath ["lib","simple"]
        Just path -> if overloadingFromOptions options
                     then return path
                     else return $ joinPath [path,"simple"] -- The lib will be part of path already.

    let (filePath, moduleName, _) = splitFilePath fullName
        filePath' = if null filePath then "." else filePath
        lvmPath   = filter (not.null) . nub
                  $ (filePath' : lvmPathFromOptionsOrEnv) ++ [baseLibs] -- baseLibs always last
    
    -- File that is compiled must exist, this test doesn't use the search path
    fileExists <- doesFileExist fullName
    newFullName <- 
        if fileExists then 
            return fullName
        else do
            let filePlusHS = fullName ++ ".hs"
            filePlusHSExists <- doesFileExist filePlusHS
            unless filePlusHSExists $ do
                putStrLn $ "Can't find file " ++ show fullName ++ " or " ++ show filePlusHS
                exitWith (ExitFailure 1)
            return filePlusHS

    -- Ensure .core libs are compiled to .lvm
    mapM_ (makeCoreLib baseLibs) coreLibs    
    
    -- And now deal with Prelude
    preludeRef <- newIORef []
    _ <- make filePath' (joinPath [baseLibs,prelude]) lvmPath [prelude] options preludeRef

    doneRef <- newIORef []
    _ <- make filePath' newFullName lvmPath [moduleName] options doneRef
    return ()


    
-- fullName = file name including path of ".hs" file that is to be compiled
-- lvmPath = where to look for files
-- chain = chain of imports that led to the current module
-- options = the compiler options
-- doneRef = an IO ref to a list of already compiled files
--                        (their names and whether they were recompiled or not)
-- returns: recompiled or not? (true = recompiled)
make :: String -> String -> [String] -> [String] -> [Option] -> IORef [(String, Bool)] -> IO Bool
make basedir fullName lvmPath chain options doneRef =
    do
        -- If we already compiled this module, return the result we already know
        done <- readIORef doneRef
        
        case lookup fullName done of 
          Just isRecompiled -> return isRecompiled
          Nothing -> do
            
            imports <- parseOnlyImports fullName
            
            -- If this module imports a module earlier in the chain, there is a cycle
            case circularityCheck imports chain of
                Just cycl -> do
                      putStrLn $ "Circular import chain: \n\t" ++ showImportChain cycl ++ "\n"
                      exitWith (ExitFailure 1)
                Nothing -> 
                    return ()
                        
            -- Find all imports in the search path
            resolvedImports <- mapM (resolve lvmPath) imports
            
            -- For each of the imports...
            compileResults <- forM (zip imports resolvedImports) 
              $ \(importModuleName, maybeImportFullName) -> do

                -- Issue error if import can not be found in the search path
                case maybeImportFullName of
                    Nothing -> do
                        putStrLn $ 
                            "Can't find module '" ++ importModuleName ++ "'\n" ++ 
                            "Import chain: \n\t" ++ showImportChain (chain ++ [importModuleName]) ++
                            "\nSearch path:\n" ++ showSearchPath lvmPath
                        exitWith (ExitFailure 1)
                    Just _ -> return ()

                let importFullName = fromJust maybeImportFullName
                -- TODO : print names imported modules in verbose mode.
                
                -- If we only have an ".lvm" file we do not need to (/can't) recompile 
                if ".lvm" `isSuffixOf` importFullName then
                    return False
                  else
                    make basedir importFullName lvmPath (chain ++ [importModuleName]) options doneRef

            -- Recompile the current module if:
            --  * any of the children was recompiled
            --  * the build all option (-B) was on the command line
            --  * the build one option (-b) was there and we are 
            --      compiling the top-most module (head of chain)
            --  * the module is not up to date (.hs newer than .lvm)
            let (filePath, moduleName, _) = splitFilePath fullName
            upToDate <- upToDateCheck (combinePathAndFile filePath moduleName)
            newDone <- readIORef doneRef
            isRecompiled <- 
                if or compileResults || 
                    BuildAll `elem` options || 
                    (BuildOne `elem` options && moduleName == head chain) ||
                    not upToDate 
                    then do
                        compile basedir fullName options lvmPath (map fst newDone)
                        return True
                      else do
                        putStrLn (moduleName ++ " is up to date")
                        return False
            
            -- Remember the fact that we have already been at this module
            writeIORef doneRef ((fullName, isRecompiled):newDone)
            return isRecompiled
            
showImportChain :: [String] -> String
showImportChain = intercalate " imports "

showSearchPath :: [String] -> String
showSearchPath = unlines . map ("\t" ++)

preludeImportsPrelude :: [String] -> Bool 
preludeImportsPrelude [x,y] = x == prelude && y == prelude
preludeImportsPrelude _ = False

circularityCheck :: [String] -> [String] -> Maybe [String]
circularityCheck (import_:imports) chain =
    case elemIndex import_ chain of
        Just index -> Just (drop index chain ++ [import_])
        Nothing -> circularityCheck imports chain
circularityCheck [] _ = Nothing

-- | upToDateCheck returns true if the .lvm is newer than the .hs
upToDateCheck :: String -> IO Bool
upToDateCheck basePath = do
    let lvmPath = basePath ++ ".lvm"
        hsPath = basePath ++ ".hs"
    lvmExists <- doesFileExist (lvmPath)
    if lvmExists then do
        t1 <- getModificationTime hsPath
        t2 <- getModificationTime lvmPath
        if t1 == t2
          then do -- If the times are equal and the files are not writable,
                -- we assume that it was installed in a system directory
                -- and therefore consider it up to date.
               let isReadOnly file = (not . writable) `fmap` getPermissions file
               lvmReadOnly <- isReadOnly lvmPath
               hsReadOnly <- isReadOnly hsPath
               -- Up to date if both are read only (and of equal mod time)
               return (lvmReadOnly && hsReadOnly)
          else return (t1 < t2)
     else
        return False
