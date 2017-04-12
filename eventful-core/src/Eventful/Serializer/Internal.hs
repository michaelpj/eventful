module Eventful.Serializer.Internal
  ( mkSumTypeSerializer
  ) where

import Data.Char (toLower)
import Data.List (find)
import Language.Haskell.TH

-- | This is a template haskell function that creates a 'Serializer' between
-- two sum types. The first sum type must be a subset of the second sum type.
-- This is useful in situations where you define all the events in your system
-- in one type, and you want to create sum types that are subsets for each
-- 'Projection'.
--
-- For example, assume we have the following three event types and two sum
-- types holding these events:
--
-- @
--    data EventA = EventA
--    data EventB = EventB
--    data EventC = EventC
--
--    data AllEvents
--      = AllEventsEventA EventA
--      | AllEventsEventB EventB
--      | AllEventsEventC EventC
--
--    data MyEvents
--      = MyEventsEventA EventA
--      | MyEventsEventB EventB
-- @
--
-- In this case, @AllEvents@ holds all the events in our system, and @MyEvents@
-- holds some subset of @AllEvents@. If we run
--
-- @
--    mkSumTypeSerializer "myEventsSerializer" ''MyEvents ''AllEvents
-- @
--
-- we will produce the following code:
--
-- @
--    -- Serialization function
--    myEventsToAllEvents :: MyEvents -> AllEvents
--    myEventsToAllEvents (MyEventsEventA e) = AllEventsEventA e
--    myEventsToAllEvents (MyEventsEventB e) = AllEventsEventB e
--
--    -- Deserialization function
--    allEventsToMyEvents :: AllEvents -> Maybe MyEvents
--    allEventsToMyEvents (AllEventsEventA e) = Just (MyEventsEventA e)
--    allEventsToMyEvents (AllEventsEventB e) = Just (MyEventsEventB e)
--    allEventsToMyEvents _ = Nothing
--
--    -- Serializer
--    myEventsSerializer :: Serializer MyEvents AllEvents
--    myEventsSerializer = simpleSerializer myEventsToAllEvents allEventsToMyEvents
-- @
mkSumTypeSerializer :: String -> Name -> Name -> Q [Dec]
mkSumTypeSerializer serializerName sourceType targetType = do
  -- Get the constructors for both types and match them up based on event type.
  sourceConstructors <- reify sourceType >>= typeConstructors sourceType
  targetConstructors <- reify targetType >>= typeConstructors targetType
  bothConstructors <- mapM (matchConstructor targetConstructors) sourceConstructors

  let
    sourceTypeName = nameBase sourceType
    targetTypeName = nameBase targetType

    -- Construct the serialization function
    serializeFuncName = mkName $ firstCharToLower sourceTypeName ++ "To" ++ targetTypeName
    serializeTypeDecl = AppT (AppT ArrowT (ConT sourceType)) (ConT targetType)
    serializeFuncClauses = map mkSerializeFunc bothConstructors

    -- Construct the deserialization function
    deserializeFuncName = mkName $ firstCharToLower targetTypeName ++ "To" ++ sourceTypeName
    deserializeTypeDecl = AppT (AppT ArrowT (ConT targetType)) (AppT (ConT ''Maybe) (ConT sourceType))
    wildcardDeserializeClause = Clause [WildP] (NormalB (ConE 'Nothing)) []
    deserializeFuncClauses = map mkDeserializeFunc bothConstructors ++ [wildcardDeserializeClause]

    -- Construct the serializer
    serializerTypeDecl = AppT (AppT (ConT (mkName "Serializer")) (ConT sourceType)) (ConT targetType)
    serializerExp = AppE (AppE (VarE (mkName "simpleSerializer")) (VarE serializeFuncName)) (VarE deserializeFuncName)
    serializerClause = Clause [] (NormalB serializerExp) []

  return
    [ -- Serialization
      SigD serializeFuncName serializeTypeDecl
    , FunD serializeFuncName serializeFuncClauses

      -- Deserialization
    , SigD deserializeFuncName deserializeTypeDecl
    , FunD deserializeFuncName deserializeFuncClauses

      -- Serializer
    , SigD (mkName serializerName) serializerTypeDecl
    , FunD (mkName serializerName) [serializerClause]
    ]

-- | Extract the constructors and event types for the given type.
typeConstructors :: Name -> Info -> Q [(Type, Name)]
typeConstructors typeName (TyConI (DataD _ _ _ _ constructors _)) = mapM go constructors
  where
    go (NormalC name []) = fail $ "Constructor " ++ nameBase name ++ " doesn't have any arguments"
    go (NormalC name [(_, type')]) = return (type', name)
    go (NormalC name _) = fail $ "Constructor " ++ nameBase name ++ " has more than one argument"
    go _ = fail $ "Invalid constructor in " ++ nameBase typeName
typeConstructors name _ = fail $ nameBase name ++ " must be a sum type"

-- | Find the corresponding target constructor for a given source constructor.
matchConstructor :: [(Type, Name)] -> (Type, Name) -> Q BothConstructors
matchConstructor targetConstructors (type', sourceConstructor) = do
  (_, targetConstructor) <-
    maybe
    (fail $ "Can't find constructor in target type corresponding to " ++ nameBase sourceConstructor)
    return
    (find ((== type') . fst) targetConstructors)
  return $ BothConstructors type' sourceConstructor targetConstructor

-- | Utility type to hold the source and target constructors for a given event
-- type.
data BothConstructors =
  BothConstructors
  { eventType :: Type
  , sourceConstructor :: Name
  , targetConstructor :: Name
  }

-- | Construct the TH function 'Clause' for the serialization function for a
-- given type.
mkSerializeFunc :: BothConstructors -> Clause
mkSerializeFunc BothConstructors{..} =
  let
    patternMatch = ConP sourceConstructor [VarP (mkName "e")]
    constructor = AppE (ConE targetConstructor) (VarE (mkName "e"))
  in Clause [patternMatch] (NormalB constructor) []

-- | Construct the TH function 'Clause' for the deserialization function for a
-- given type.
mkDeserializeFunc :: BothConstructors -> Clause
mkDeserializeFunc BothConstructors{..} =
  let
    patternMatch = ConP targetConstructor [VarP (mkName "e")]
    constructor = AppE (ConE 'Just) (AppE (ConE sourceConstructor) (VarE (mkName "e")))
  in Clause [patternMatch] (NormalB constructor) []

firstCharToLower :: String -> String
firstCharToLower [] = []
firstCharToLower (x:xs) = toLower x : xs