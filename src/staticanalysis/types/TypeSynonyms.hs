-------------------------------------------------------------------------------
--
--   *** The Helium Compiler : Static Analysis ***
--               ( Bastiaan Heeren )
--
-- TypeSynonyms.hs : Representation and utility-functions
--
-------------------------------------------------------------------------------

module TypeSynonyms where

import TypeBasics
import TypeRepresentation
import FiniteMap
import TopSort               ( topSort       ) 
import Utils                 ( internalError )

----------------------------------------------------------------------
-- type synonyms

type OrderedTypeSynonyms = (TypeSynonymOrdering, TypeSynonyms)
type TypeSynonyms        = FiniteMap String (Int, Tps -> Tp)
type TypeSynonymOrdering = FiniteMap String Int

noOrderedTypeSynonyms :: OrderedTypeSynonyms
noOrderedTypeSynonyms = (emptyFM, emptyFM)

-- fully expand a type in a recursive way
expandType :: TypeSynonyms -> Tp -> Tp
expandType synonyms tp =    
   let (x,xs) = leftSpine (expandTypeConstructor synonyms tp)
   in foldl TApp x (map (expandType synonyms) xs)

-- fully expand the (top-level) type constructor      
expandTypeConstructor :: TypeSynonyms -> Tp -> Tp
expandTypeConstructor synonyms tp = 
   maybe tp (expandTypeConstructor synonyms) (expandTypeConstructorOneStep synonyms tp)

-- expand the (top-level) type constructor one step.
expandTypeConstructorOneStep :: TypeSynonyms -> Tp -> Maybe Tp
expandTypeConstructorOneStep synonyms tp = 
   case leftSpine tp of 
      (TCon s, tps) -> case lookupFM synonyms s of
                          Just (i, f) | i == length tps -> Just (f tps)
                                      | otherwise       -> internalError "TypeSynonyms.hs" 
                                                                         "expandTypeConstructorOneStep" 
                                                                         "invalid arity of type synonym"
                          Nothing     -> Nothing
      _             -> Nothing     

-- try to expand the (top-level) type constructor of one of the types. 
expandOneStepOrdered :: OrderedTypeSynonyms -> (Tp, Tp) -> Maybe (Tp, Tp)
expandOneStepOrdered (ordering, synonyms) (t1,t2) = 
   let f tp = case fst (leftSpine tp) of 
                 TCon s -> lookupFM ordering s 
                 _      -> Nothing
       expand tp = case expandTypeConstructorOneStep synonyms tp of
                      Just x  -> x
                      Nothing -> internalError "TypeSynonyms.hs" "expandOneStep" "invalid set of OrderedTypeSynonyms"
   in case (f t1, f t2) of
         (Just i1, Just i2) | i1 < i2   -> Just (expand t1, t2)
                            | otherwise -> Just (t1, expand t2)
         (Just i1, Nothing) -> Just (expand t1, t2)
         (Nothing, Just i2) -> Just (t1, expand t2)
         _                  -> Nothing

-- determine an ordering of the type synonyms 
--     (and you may find mutually recursive type synonyms!)
getTypeSynonymOrdering :: TypeSynonyms -> (TypeSynonymOrdering, [[String]])
getTypeSynonymOrdering synonyms = 
   let 
       (nameTable, intTable) = let keys = keysFM synonyms
                               in ( listToFM (zip keys [0..])
                                  , listToFM (zip [0..] keys)
                                  )
       
       err        = internalError "TypeSynonyms.hs" "getTypeSynonymOrdering" "error in lookup table"
       lookupName = maybe err id . lookupFM nameTable
       lookupInt  = maybe err id . lookupFM intTable
       
       edges = let op s1 (arity, function) es = 
                      let i1 = lookupName s1
                          cs = constantsInType (function (map TVar [0 .. arity - 1]))
                          add s2 = case lookupFM nameTable s2 of
                                      Just i2 -> (:) (i2,i1)
                                      Nothing -> id
                      in foldr add es cs
               in foldFM op [] synonyms

       list = reverse (topSort (sizeFM synonyms - 1) edges)

       (ordering, recursive, _) =  
          let op ints (os, rs, counter) = 
                 case ints of
                    [int] | (int, int) `notElem` edges     -- correct type synonym
                      -> (addToFM os (lookupInt int) counter, rs, counter + 1)
                    _ -> (os, map lookupInt ints : rs, counter)
          in foldr op (emptyFM, [], 0) list
   in 
      (ordering, recursive)
