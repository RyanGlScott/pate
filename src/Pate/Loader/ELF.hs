{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase   #-}


module Pate.Loader.ELF (
    LoadedELF(..)
  , LoadedElfPair(..)
  , LoadPaths(..)
  , simplePaths
  , LoaderM
  , loadELF
  , loadELFs
  ) where

import qualified Control.Monad.Except as CME
import qualified Control.Monad.Writer as CMW
import qualified Control.Monad.IO.Class as IO

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Parameterized.Classes as DPC
import           Data.Proxy ( Proxy(..) )
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.Classes as PC
import qualified Data.Traversable as T
import           Data.Maybe ( maybeToList )

import qualified Data.ElfEdit as DEE
import qualified Data.ElfEdit.Prim as EEP
import qualified Data.Macaw.Memory.ElfLoader as MME
import qualified Data.Macaw.Architecture.Info as MI
import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.BinaryLoader as MBL

import qualified Pate.Arch as PA
import qualified Pate.Equivalence.Error as PEE
import           Pate.Panic
import qualified Pate.Hints as PH
import qualified Pate.Hints.CSV as PHC
import qualified Pate.Hints.DWARF as PHD
import qualified Pate.Hints.JSON as PHJ
import qualified Pate.Hints.BSI as PHB

data LoadedELF arch =
  LoadedELF
    { archInfo :: MI.ArchitectureInfo arch
    , loadedBinary :: MBL.LoadedBinary arch (DEE.ElfHeaderInfo (MC.ArchAddrWidth arch))
    , loadedHeader :: DEE.ElfHeader (MC.ArchAddrWidth arch)
    }

data LoadPaths = LoadPaths
   { binPath :: FilePath
   , anvillHintsPaths :: [FilePath]
   , mprobHintsPath :: Maybe FilePath
   , mcsvHintsPath :: Maybe FilePath
   , mbsiHintsPath :: Maybe FilePath
   }

-- | A 'LoadPaths' with only the path to the binary defined
simplePaths :: FilePath -> LoadPaths
simplePaths fp = LoadPaths fp [] Nothing Nothing Nothing

-- a LoadError exception is unrecoverable, while written results should just be raised
-- as warnings
type LoaderM = CMW.WriterT [PEE.LoadError] (CME.ExceptT PEE.LoadError IO)

loadELF ::
  forall arch.
  PA.SomeValidArch arch ->
  FilePath ->
  LoaderM (LoadedELF arch)
loadELF (PA.SomeValidArch{}) path = do
  bs <- IO.liftIO $ BS.readFile path
  elf <- doParse bs
  mem <- IO.liftIO $ MBL.loadBinary MME.defaultLoadOptions elf
  return $ LoadedELF
    { archInfo = PA.binArchInfo mem
    , loadedBinary = mem
    , loadedHeader = (DEE.header elf)
    }
  where
    archWidthRepr :: MC.AddrWidthRepr (MC.ArchAddrWidth arch)
    archWidthRepr = MC.addrWidthRepr (Proxy @(MC.ArchAddrWidth arch))

    doParse :: BS.ByteString -> LoaderM (DEE.ElfHeaderInfo (MC.ArchAddrWidth arch))
    doParse bs = case DEE.decodeElfHeaderInfo bs of
      Left (off, msg) -> CME.throwError $ PEE.ElfHeaderParseError path off msg
      Right (DEE.SomeElf h) -> case DEE.headerClass (DEE.header h) of
        DEE.ELFCLASS32 -> return $ getElf h
        DEE.ELFCLASS64 -> return $ getElf h

    getElf :: forall w. MC.MemWidth w => DEE.ElfHeaderInfo w -> DEE.ElfHeaderInfo (MC.ArchAddrWidth arch)
    getElf e = case DPC.testEquality (MC.addrWidthRepr e) archWidthRepr of
      Just DPC.Refl -> e
      Nothing -> panic Loader "LoadElf" [ "Unexpected arch pointer width"
                                        , "expected: " ++ show archWidthRepr
                                        , "but got: " ++ show (MC.addrWidthRepr e)
                                        ]

data LoadedElfPair arch =
  LoadedElfPair (PA.SomeValidArch arch) (PH.Hinted (LoadedELF arch)) (PH.Hinted (LoadedELF arch))

loadELFs ::
  PA.ArchLoader PEE.LoadError ->
  LoadPaths ->
  LoadPaths ->
  Bool {- ^ use dwarf hints -} ->
  LoaderM (Some LoadedElfPair)
loadELFs archLoader origPaths patchedPaths useDwarf = do
  let fpOrig = binPath origPaths
  let fpPatched = binPath patchedPaths
  (IO.liftIO $ archToProxy archLoader fpOrig fpPatched) >>= \case
    Left err -> CME.throwError err
    Right (elfErrs, Some proxy) -> do
      CMW.tell (fmap PEE.ElfParseError elfErrs)
      elfOrig <- loadELF proxy fpOrig
      origHints <- parseHints origPaths useDwarf
      elfPatched <- loadELF proxy fpPatched
      patchedHints <- parseHints patchedPaths useDwarf
      return $ Some (LoadedElfPair proxy (PH.Hinted origHints elfOrig) (PH.Hinted patchedHints elfPatched))

-- | Examine the input files to determine the architecture
archToProxy :: PA.ArchLoader PEE.LoadError -> FilePath -> FilePath -> IO (Either PEE.LoadError ([DEE.ElfParseError], Some PA.SomeValidArch))
archToProxy (PA.ArchLoader machineToProxy) origBinaryPath patchedBinaryPath = do
  origBin <- BS.readFile origBinaryPath
  patchedBin <- BS.readFile patchedBinaryPath
  case (EEP.decodeElfHeaderInfo origBin, EEP.decodeElfHeaderInfo patchedBin) of
    (Right (EEP.SomeElf origHdr), Right (EEP.SomeElf patchedHdr))
      | Just PC.Refl <- PC.testEquality (DEE.headerClass (DEE.header origHdr)) (DEE.headerClass (DEE.header patchedHdr))
      , DEE.headerMachine (DEE.header origHdr) == DEE.headerMachine (DEE.header patchedHdr) ->
        let (origParseErrors, _origElf) = DEE.getElf origHdr
            (patchedParseErrors, _patchedElf) = DEE.getElf patchedHdr
            origMachine = DEE.headerMachine (DEE.header origHdr)
        in return (fmap (origParseErrors ++ patchedParseErrors,) (machineToProxy origMachine origHdr patchedHdr))
    (Left (off, msg), _) -> return (Left (PEE.ElfHeaderParseError origBinaryPath off msg))
    (_, Left (off, msg)) -> return (Left (PEE.ElfHeaderParseError patchedBinaryPath off msg))
    _ -> return (Left (PEE.ElfArchitectureMismatch origBinaryPath patchedBinaryPath))


parseHints
  :: LoadPaths ->
     Bool {- ^ use dwarf hints -} ->
     LoaderM PH.VerificationHints
parseHints paths useDwarf = do
  anvills <- T.forM (anvillHintsPaths paths) $ \anvillFile -> do
    bytes <- IO.liftIO $ BSL.readFile anvillFile
    let (hints, errs) = PHJ.parseAnvillSpecHints bytes
    CMW.tell (fmap (PEE.JSONParseError anvillFile) errs)
    return hints

  probs <- T.forM (maybeToList (mprobHintsPath paths)) $ \probFile -> do
    bytes <- IO.liftIO $ BSL.readFile probFile
    let (hints, errs) = PHJ.parseProbabilisticHints bytes
    CMW.tell (fmap (PEE.JSONParseError probFile) errs)
    return hints

  csvs <- T.forM (maybeToList (mcsvHintsPath paths)) $ \csvFile -> do
    bytes <- IO.liftIO $ BSL.readFile csvFile
    let (hints, errs) = PHC.parseFunctionHints bytes
    CMW.tell (fmap (PEE.CSVParseError csvFile) errs)
    return hints

  let dwarfSource = if useDwarf then [binPath paths] else []
  dwarves <- T.forM dwarfSource $ \elfFile -> do
    bytes <- IO.liftIO $ BSL.readFile elfFile
    let (hints, errs) = PHD.parseDWARFHints bytes
    CMW.tell (fmap (PEE.DWARFError elfFile) errs)
    return hints

  bsis <- T.forM (maybeToList (mbsiHintsPath paths)) $ \bsiFile -> do
    bytes <- IO.liftIO $ BSL.readFile bsiFile
    let (hints, errs) = PHB.parseSymbolSpecHints bytes
    CMW.tell (fmap (PEE.BSIParseError bsiFile) errs)
    return hints

  return (mconcat (concat [anvills, probs, csvs, dwarves, bsis]))
