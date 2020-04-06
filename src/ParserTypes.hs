module ParserTypes where

import           Data.List.NonEmpty (NonEmpty)
import           Data.Text          (Text)
import           Data.Void
import           Text.Megaparsec
import qualified Text.Megaparsec.Char.Lexer as L

type Parser = Parsec Void Text

type IndentOpt = L.IndentOpt Parser

data SimpleType = IntType | FloatType | BoolType | StringType | CharType deriving (Eq,Show)

data ComposedType = Simple SimpleType | ArrayType SimpleType Int | ClassType Text deriving (Eq,Show)

data ReturnType = ValueReturn SimpleType | VoidReturn deriving (Eq,Show)

data Statement = Continue | Break | Pass deriving (Eq,Show)

data FunctionArgument = FunctionArgument { argumentName :: Text,
                                           argumentType :: SimpleType
                                         } deriving (Eq,Show)

data Function = Function { functionName       :: Text,
                           functionArguments  :: [FunctionArgument],
                           functionReturnType :: ReturnType,
                           functionStatements :: NonEmpty Statement
                         } deriving (Eq,Show)
