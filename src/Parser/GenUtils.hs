module Parser.GenUtils where

import           Control.Category
import           Control.Monad.State.Lazy
import           Data.Foldable
import qualified Data.HashMap.Strict      as H
import           Data.List.NonEmpty       (NonEmpty)
import qualified Data.List.NonEmpty       as N
import qualified Data.Sequence            as S
import           Parser.AnalysisUtils
import           Parser.ParserTypes
import           Parser.Utils

quadruplesCounter :: ParserState -> Int
quadruplesCounter ParserState{quadruplesSequence=quads} = S.length quads

addQuadruple :: Quad -> ParserState -> ParserState
addQuadruple quad pState@ParserState{quadruplesSequence=quads}= pState{ quadruplesSequence = quads S.|> quad}

registerQuadruple :: Quad -> Parser ()
registerQuadruple = modify <<< addQuadruple

updateQuadruple :: Int -> Quad -> ParserState -> ParserState
updateQuadruple index quad pState@ParserState{quadruplesSequence=quads} = pState {quadruplesSequence= S.update index quad quads}

lookupQuadruple :: Int -> ParserState -> Maybe Quad
lookupQuadruple i ParserState{quadruplesSequence=quads} = quads S.!? i

safeQuadrupleUpdate :: (Quad -> Either String Quad) -> Int -> Parser ()
safeQuadrupleUpdate f index = do
  mQuad <- gets $ lookupQuadruple index
  quad <- maybeFail ("No quadruple at index " ++ show index) mQuad
  newQuad <- liftEither <<< f $ quad
  modify $ updateQuadruple index newQuad

fillGOTOF :: Int -> Quad -> Either String Quad
fillGOTOF index (QuadFPlaceholder address) = Right $ QuadF address index
fillGOTOF _ quad = Left $ show quad ++ " is not goto false placeholder"

fillGOTOT :: Int -> Quad -> Either String Quad
fillGOTOT index (QuadTPlaceholder address) = Right $ QuadT address index
fillGOTOT _ quad = Left $ show quad ++ " is not goto true placeholder"

fillGOTO :: Int -> Quad -> Either String Quad
fillGOTO index QuadGOTOPlaceholder = Right $ QuadGOTO index
fillGOTO _  quad = Left $ show quad ++ " is not goto placeholder"

writeLoopJumps :: Int -> Int -> ScopeType -> Parser ()
writeLoopJumps continueLocation breakLocation (ScopeTypeWhile continues breaks) = do
  forM_ continues (safeQuadrupleUpdate (fillGOTO continueLocation))
  forM_ breaks (safeQuadrupleUpdate (fillGOTO breakLocation))
writeLoopJumps continueLocation breakLocation (ScopeTypeFor continues breaks) = do
  forM_ continues (safeQuadrupleUpdate (fillGOTO continueLocation))
  forM_ breaks (safeQuadrupleUpdate (fillGOTO breakLocation))
writeLoopJumps _ _ _ = fail "Trying to make continue and break jumps with no loop scope"

addContinue :: Int -> ScopeType -> ScopeType
addContinue index (ScopeTypeFor continues breaks) = ScopeTypeFor (index:continues) breaks
addContinue index (ScopeTypeWhile continues breaks) = ScopeTypeWhile (index : continues) breaks
addContinue _ s = s

addBreak :: Int -> ScopeType -> ScopeType
addBreak index (ScopeTypeFor continues breaks) = ScopeTypeFor continues (index:breaks)
addBreak index (ScopeTypeWhile continues breaks) = ScopeTypeWhile continues (index:breaks)
addBreak _ s = s

transformFirstLoop :: (ScopeType -> ScopeType) -> Scope -> State Bool Scope
transformFirstLoop transformation scope = do
  isTransformed <- get
  let sType = scopeType scope
  if isTransformed || not (isLoop sType)
    then return scope
    else scope{scopeType=transformation sType} <$ put True
  where
    isLoop (ScopeTypeFor _ _)   = True
    isLoop (ScopeTypeWhile _ _) = True
    isLoop _                    = False

addBreakToLoop :: Parser ()
addBreakToLoop = do
  cont <- gets quadruplesCounter
  registerQuadruple QuadGOTOPlaceholder
  pState@ParserState{scopes=ss} <- get
  let transformedScopes = evalState (forM ss (transformFirstLoop $ addBreak cont)) False
  put pState{scopes=transformedScopes}

addContinueToLoop :: Parser ()
addContinueToLoop = do
  cont <- gets quadruplesCounter
  registerQuadruple QuadGOTOPlaceholder
  pState@ParserState{scopes=ss} <- get
  let transformedScopes = evalState (forM ss (transformFirstLoop $ addContinue cont)) False
  put pState{scopes=transformedScopes}

memoryBlockToMaybeAddress :: TypeMemoryBlock -> Maybe Address
memoryBlockToMaybeAddress (TypeMemoryBlock _ mUBound cDirection)
  | cDirection <= mUBound = Just (Address cDirection)
  | otherwise = Nothing

getNextAddress :: SimpleType -> MemoryBlock -> Maybe Address
getNextAddress IntType   = memoryBlockToMaybeAddress <<< memoryBlockInt
getNextAddress FloatType = memoryBlockToMaybeAddress <<< memoryBlockFloat
getNextAddress CharType  = memoryBlockToMaybeAddress <<< memoryBlockChar
getNextAddress BoolType  = memoryBlockToMaybeAddress <<< memoryBlockBool

getScopeTempMemoryBlock :: ParserState -> MemoryBlock
getScopeTempMemoryBlock ParserState{scopes=Scope{scopeTempMemory=memory} N.:| _} = memory

updateTypeMemory :: TypeMemoryBlock -> TypeMemoryBlock -> Either String TypeMemoryBlock
updateTypeMemory (TypeMemoryBlock lower upper current) (TypeMemoryBlock newLower newUpper newCurrent)
  | lower == newLower && upper == newUpper = Right (TypeMemoryBlock lower upper (max current newCurrent))
  | otherwise = Left "Type memory blocks do not share size"

updateMemoryBlock :: MemoryBlock -> MemoryBlock -> Either String MemoryBlock
updateMemoryBlock (MemoryBlock mbi mbf mbc mbb) (MemoryBlock nmbi nmbf nmbc nmbb) = MemoryBlock
  <$> updateTypeMemory mbi nmbi
  <*> updateTypeMemory mbf nmbf
  <*> updateTypeMemory mbc nmbc
  <*> updateTypeMemory mbb nmbb

memoryBlockIncrease :: Int -> TypeMemoryBlock -> TypeMemoryBlock
memoryBlockIncrease increase (TypeMemoryBlock mLBound mUBound cDirection) = TypeMemoryBlock mLBound mUBound (cDirection + increase)

increaseCurrentAddress :: Int -> SimpleType -> MemoryBlock -> MemoryBlock
increaseCurrentAddress increase IntType (MemoryBlock tMBI tMF tMC tMB) = MemoryBlock (memoryBlockIncrease increase tMBI) tMF tMC tMB
increaseCurrentAddress increase FloatType (MemoryBlock tMBI tMF tMC tMB) = MemoryBlock tMBI (memoryBlockIncrease increase tMF) tMC tMB
increaseCurrentAddress increase CharType (MemoryBlock tMBI tMF tMC tMB) = MemoryBlock tMBI tMF (memoryBlockIncrease increase tMC) tMB
increaseCurrentAddress increase BoolType (MemoryBlock tMBI tMF tMC tMB) = MemoryBlock tMBI tMF tMC (memoryBlockIncrease increase tMB)

getNextTypeAddress :: Int -> SimpleType -> MemoryBlock -> Parser (MemoryBlock, Address)
getNextTypeAddress increase sT mB = do
  let mAddress = getNextAddress sT mB
  address <- maybeFail "Out of memory error" mAddress
  return (increaseCurrentAddress increase sT mB, address)

currentMemoryBlock :: ParserState -> MemoryBlock
currentMemoryBlock ParserState{scopes=(Scope{scopeVariablesMemory=memoryBlock} N.:| _)} = memoryBlock

currentTempBlock :: ParserState -> MemoryBlock
currentTempBlock ParserState{scopes=(Scope{scopeTempMemory=memoryBlock} N.:| _)} = memoryBlock

updateCurrentMemoryBlock :: MemoryBlock -> ParserState -> ParserState
updateCurrentMemoryBlock memoryBlock pState@ParserState{scopes=(currentScope@Scope{} N.:| restScopes)} = pState {scopes=currentScope{scopeVariablesMemory=memoryBlock} N.:| restScopes}

updateCurrentTemp :: MemoryBlock -> ParserState -> ParserState
updateCurrentTemp memoryBlock pState@ParserState{scopes=(currentScope@Scope{} N.:| restScopes)} = pState {scopes=currentScope{scopeTempMemory=memoryBlock} N.:| restScopes}

data DataType = VarData | TempData deriving (Eq,Show)

nextAddress :: DataType -> (ParserState -> MemoryBlock) -> (MemoryBlock -> ParserState -> ParserState) -> (FunctionDefinition -> MemoryBlock) -> ( MemoryBlock -> FunctionDefinition -> FunctionDefinition) -> Int -> SimpleType -> Parser Address
nextAddress datatype fetch push memBlock memUpdate increase sType = do
  (nMB, address) <- nextAddressNoFunc fetch push increase sType
  isInsideFunction <- insideFunction
  when isInsideFunction $ do
      fName <- findScopeFunctionName
      functionDefinition <- findFunction fName
      let oldMemoryBlock = memBlock functionDefinition
      maxMB <- liftEither $ updateMemoryBlock oldMemoryBlock nMB
      let newFDef = memUpdate maxMB functionDefinition
      modify $ insertFunction fName newFDef
  isGlobalScope <- currentScopeIsGlobal
  when isGlobalScope $ do
      oldMemoryBlock <- case datatype of
        VarData  -> gets globalVariablesBlock
        TempData -> gets globalTempBlock
      maxMB <- liftEither $ updateMemoryBlock oldMemoryBlock nMB
      modify $ f maxMB
  return address
  where
    f mBlock pState = case datatype of
      VarData  -> pState{globalVariablesBlock = mBlock}
      TempData -> pState{globalTempBlock = mBlock}

nextAddressNoFunc :: (ParserState -> MemoryBlock) -> (MemoryBlock -> ParserState -> ParserState) -> Int -> SimpleType -> Parser (MemoryBlock, Address)
nextAddressNoFunc fetch push increase sType = do
  mB <- gets fetch
  (nMB, address) <- getNextTypeAddress increase sType mB
  (nMB, address) <$ (modify <<< push) nMB

nextVarAddressGeneral :: Int -> SimpleType -> Parser Address
nextVarAddressGeneral = nextAddress VarData currentMemoryBlock updateCurrentMemoryBlock functionDefinitionVarMB updateDef
  where
    updateDef mB fDef = fDef{functionDefinitionVarMB = mB}

nextVarAddress :: SimpleType -> Parser Address
nextVarAddress = nextVarAddressGeneral 1

nextTempAddressGeneral :: Int -> SimpleType -> Parser Address
nextTempAddressGeneral = nextAddress TempData currentTempBlock updateCurrentTemp functionDefinitionTempMB updateDef
  where
    updateDef mB fDef = fDef{functionDefinitionTempMB = mB}

nextTempAddress :: SimpleType -> Parser Address
nextTempAddress = nextTempAddressGeneral 1

updateGlobalScope :: Scope -> ParserState -> ParserState
updateGlobalScope scope pState@ParserState{scopes = ss} = pState{scopes = f <$> ss}
  where
    f Scope{scopeType = ScopeTypeGlobal} = scope
    f s                                  = s

nextGlobalVarAddressGeneral :: Int -> SimpleType -> Parser Address
nextGlobalVarAddressGeneral increase sType = do
  ss <- gets scopes
  let mGlobalScope = asum $ f <$> ss
  globalScope <- maybeFail "Non existent global scope" mGlobalScope
  let mB = scopeVariablesMemory globalScope
  (nMB, address) <- getNextTypeAddress increase sType mB
  let updatedGlobalScope = globalScope{scopeVariablesMemory = nMB}
  modify $ updateGlobalScope updatedGlobalScope
  globalMem <- gets globalVariablesBlock
  maxMB <- liftEither $  updateMemoryBlock globalMem nMB
  modify (\pState -> pState{globalVariablesBlock = maxMB})
  return address
  where
    f scope@Scope{scopeType = ScopeTypeGlobal} = Just scope
    f _                                        = Nothing

nextGlobalVarAddress :: SimpleType -> Parser Address
nextGlobalVarAddress = nextGlobalVarAddressGeneral 1

lookupLiteral :: Literal -> ParserState -> Maybe Address
lookupLiteral literal ParserState{literalBlock=LiteralBlock{literalAddressMap=lMap}} = H.lookup literal lMap

getLiteralMemoryBlock :: ParserState -> MemoryBlock
getLiteralMemoryBlock ParserState{literalBlock=LiteralBlock{literalMemoryBlock=mBlock}} = mBlock

updateLiteralMemoryBlock :: MemoryBlock -> ParserState -> ParserState
updateLiteralMemoryBlock memoryBlock pState@ParserState{literalBlock=lBlock@LiteralBlock{}} = pState{literalBlock=lBlock{literalMemoryBlock=memoryBlock}}

nextLiteralAddress :: Int -> SimpleType -> Parser Address
nextLiteralAddress increase sType = snd <$> nextAddressNoFunc getLiteralMemoryBlock updateLiteralMemoryBlock increase sType

insertLiteralAddress :: Literal -> Address -> ParserState -> ParserState
insertLiteralAddress literal address pState@ParserState{literalBlock=lBlock@LiteralBlock{literalAddressMap=lMap}} = pState{literalBlock=lBlock{literalAddressMap=H.insert literal address lMap}}

literalType :: Literal -> SimpleType
literalType (LiteralInt _)    = IntType
literalType (LiteralFloat _)  = FloatType
literalType (LiteralChar _)   = CharType
literalType (LiteralString _) = CharType
literalType (LiteralBool _)   = BoolType

literalSize :: Literal -> Int
literalSize (LiteralString s) = length s
literalSize _                 = 1

getLiteralAddress :: Literal -> Parser Address
getLiteralAddress literal = do
  mAddress <- gets $ lookupLiteral literal
  case mAddress of
    Just address -> return address
    Nothing -> do
      let sz = literalSize literal
      let lType = literalType literal
      address <- nextLiteralAddress sz lType
      modify $ insertLiteralAddress literal address
      return address

writeParams' :: Expr -> StateT Int Parser ()
writeParams' (Expr _ _ address) = do
  index <- get
  lift $ registerQuadruple $ QuadFuncParam address index
  put (index + 1)

writeParams :: (Foldable t) => t Expr -> Parser ()
writeParams params = evalStateT (forM_ params writeParams') 0

writeArrayAccess :: NonEmpty Expr -> NonEmpty Int -> Parser Address
writeArrayAccess indices boundaries = do
  guardFail (length indices == length boundaries) "Incorrect array dimensions"
  zero <- getLiteralAddress $ LiteralInt 0
  let indicesAddress = memoryAddress <$> indices
  boundaryAddresses <- mapM (getLiteralAddress <<< LiteralInt) (subtract 1 <$> boundaries)
  let varAddressPair = N.zip indicesAddress boundaryAddresses
  forM_ varAddressPair (writeVerification zero)
  strideAddresses <- mapM (getLiteralAddress <<< LiteralInt) (arrayStrides boundaries)
  execStateT (forM_ (N.zip strideAddresses indicesAddress) writePlainIndex) zero

writeVerification :: Address -> (Address, Address) -> Parser ()
writeVerification lowerbound (var,upperbound) = registerQuadruple $ QuadVerify var lowerbound upperbound

arrayStrides :: NonEmpty Int -> NonEmpty Int
arrayStrides (_ N.:| xs) = N.fromList $ scanr (*) 1 xs

writePlainIndex :: (Address, Address) -> StateT Address Parser ()
writePlainIndex (stride,value) = do
  accum <- get
  multAddress <- lift $ nextTempAddress IntType
  lift $ registerQuadruple $ QuadOp Times value stride multAddress
  newAccum <- lift $ nextTempAddress IntType
  lift $ registerQuadruple $ QuadOp Sum multAddress accum newAccum
  put newAccum
