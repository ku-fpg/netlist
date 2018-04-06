--------------------------------------------------------------------------------
-- |
-- Module       :  Language.Netlist.GenVHDL
-- Copyright    :  (c) University of Kansas 2010
-- License      :  All rights reserved
--
-- Maintainer   : garrin.kimmell@gmail.com
-- Stability    : experimental
-- Portability  : non-portable
--
-- Translates a Netlist AST ('Language.Netlist.AST') to VHDL.
--------------------------------------------------------------------------------

{-# LANGUAGE CPP #-}
module Language.Netlist.GenVHDL(genVHDL) where

import Language.Netlist.AST

#if MIN_VERSION_base(4,11,0)
import Prelude hiding ((<>))
#endif
import Text.PrettyPrint
import Data.Maybe(catMaybes, mapMaybe)


-- | Generate a 'Language.Netlist.AST.Module' as a VHDL file . The ['String'] argument
-- is the list of extra modules to import, typically [\"work.all\"].
genVHDL :: Module -> [String] -> String
genVHDL m others = render vhdl ++ "\n"
  where
    vhdl  =  imports others $$
             entity m $$
             architecture m

imports :: [String] -> Doc
imports others = vcat
        [ text "library IEEE" <> semi
        , text "use IEEE.STD_LOGIC_1164.ALL" <> semi
        , text "use IEEE.NUMERIC_STD.ALL" <> semi
        ] $$ vcat [
          text ("use " ++ other) <> semi
        | other <- others
        ]


entity :: Module -> Doc
entity m = text "entity" <+> text (module_name m) <+> text "is" $$
            nest 2 (text "port" <> parens (vcat $ punctuate semi ports) <> semi) $$
            text "end" <+> text "entity" <+> text (module_name m) <> semi

  where ports = [text i <+> colon <+> text "in" <+> slv_type ran | (i,ran) <- module_inputs m ] ++
                [text i <+> colon <+> text "out" <+> slv_type ran | (i,ran) <- module_outputs m ]


architecture :: Module -> Doc
architecture m = text "architecture" <+> text "str" <+> text "of" <+>  text (module_name m) <+> text "is" $$
                 nest 2 (decls (module_decls m)) $$
                 text "begin" $$
                 nest 2 (insts (module_decls m)) $$
                 text "end" <+> text "architecture" <+> text "str" <> semi

decls :: [Decl] -> Doc
decls = vcat . map (<> semi) . mapMaybe decl

decl :: Decl -> Maybe Doc
decl (NetDecl i r Nothing) = Just $
  text "signal" <+> text i <+> colon <+> slv_type r

decl (NetDecl i r (Just init')) = Just $
  text "signal" <+> text i <+> colon <+> slv_type r <+> text ":=" <+> expr init'

decl (MemDecl i Nothing dsize Nothing) = Just $
    text "signal" <+> text i <+> colon <+> slv_type dsize

decl (MemDecl i (Just asize) dsize def) = Just $
  text "type" <+> mtype  <+> text "is" <+>
       text "array" <+> range asize <+> text "of" <+> slv_type dsize <> semi $$
  text "signal" <+> text i <+> colon <+> mtype <> def_txt
 where mtype = text i <> text "_type"
       def_txt = case def of
                  Nothing -> empty
                  Just [xs] -> empty <+> text ":=" <+> parens (text "0 =>" <+> expr xs)
                  Just xs -> empty <+> text ":=" <+> parens (vcat $ punctuate comma (map expr xs))

decl _d = Nothing

insts ::  [Decl] -> Doc
insts = vcat . map (<> semi) . catMaybes . zipWith inst gensyms
  where gensyms = ["proc" ++ show i | i <- [(0::Integer)..]]

inst :: String -> Decl -> Maybe Doc
inst _ (NetAssign i e) = Just $ text i <+> text "<=" <+> expr e
inst _ (MemAssign i idx e) = Just $ text i <> parens (expr idx) <+> text "<=" <+> expr e

inst gensym (ProcessDecl (Event clk edge) Nothing s) = Just $
    text gensym <+> colon <+> text "process" <> senlist <+> text "is" $$
    text "begin" $$
    nest 2 (text "if" <+> nest 2 event <+> text "then" $$
            nest 2 (stmt s) $$
            text "end if" <> semi) $$
    text "end process" <+> text gensym
  where
    senlist = parens $ expr clk
    event   = case edge of
                PosEdge -> text "rising_edge" <> parens (expr clk)
                NegEdge -> text "falling_edge" <> parens (expr clk)

inst gensym (ProcessDecl (Event clk clk_edge)
             (Just (Event reset reset_edge, reset_stmt)) s) = Just $
    text gensym <+> colon <+> text "process" <> senlist <+> text "is" $$
    text "begin" $$
    nest 2 (text "if" <+> nest 2 reset_event <+> text "then" $$
            nest 2 (stmt reset_stmt) $$
            text "elsif" <+> nest 2 clk_event <+> text "then" $$
            nest 2 (stmt s) $$
            text "end if" <> semi) $$
    text "end process" <+> text gensym
  where
    senlist     = parens $ cat $ punctuate comma $ map expr [ clk, reset ]
    clk_event   = case clk_edge of
                    PosEdge -> text "rising_edge" <> parens (expr clk)
                    NegEdge -> text "falling_edge" <> parens (expr clk)
    reset_event = case reset_edge of
                    PosEdge -> expr reset <+> text "= '1'"
                    NegEdge -> expr reset <+> text "= '0'"


inst _ (InstDecl nm inst' gens ins outs) = Just $
  text inst' <+> colon <+> text "entity" <+> text nm $$
       gs $$
       ps
 where
   gs | null gens = empty
      | otherwise =
        text "generic map" <+>
         (parens (cat (punctuate comma  [text i <+> text "=>" <+> expr e | (i,e) <- gens])))
   -- Assume that ports is never null
   ps = text "port map" <+>
         parens (cat (punctuate comma  [text i <+> text "=>" <+> expr e | (i,e) <- (ins ++ outs)]))


inst gensym (InitProcessDecl s) = Just $
    text "-- synthesis_off" $$
    text gensym <+> colon <+> text "process" <> senlist <+> text "is" $$
    text "begin" $$
    nest 2 (stmt s) $$
    text "wait" <> semi $$
    text "end process" <+> text gensym $$
    text "-- synthesis_on"
  where senlist = parens empty

-- TODO: get multline working
inst _ (CommentDecl msg) = Just $
    (vcat [ text "--" <+> text m | m <- lines msg ])

inst _ _d = Nothing

stmt :: Stmt -> Doc
stmt (Assign l r) = expr l <+> text "<=" <+> expr r <> semi
stmt (Seq ss) = vcat (map stmt ss)
stmt (If e t Nothing) =
  text "if" <+> expr e <+> text "then" $$
  nest 2 (stmt t) $$
  text "end if" <> semi
stmt (If p t (Just e)) =
  text "if" <+> expr p <+> text "then" $$
  nest 2 (stmt t) $$
  text "else" $$
  nest 2 (stmt e) $$
  text "end if" <> semi
stmt (Case d ps def) =
    text "case" <+> expr d <+> text "of" $$
    vcat (map mkAlt ps) $$
    defDoc $$
    text "end case" <> semi
  where defDoc = maybe empty mkDefault def
        mkDefault s = text "when others =>" $$
                      nest 2 (stmt s)
        mkAlt ([g],s) = text "when" <+> expr g <+> text "=>" $$
                        nest 2 (stmt s)


to_bits :: Integral a => Int -> a -> [Bit]
to_bits size val = map (\x -> if odd x then T else F)
                   $ reverse
                   $ take size
                   $ map (`mod` 2)
                   $ iterate (`div` 2)
                   $ val

bit_char :: Bit -> Char
bit_char T = '1'
bit_char F = '0'
bit_char U = 'U'  -- 'U' means uninitialized,
                  -- 'X' means forced to unknown.
                  -- not completely sure that 'U' is the right choice here.
bit_char Z = 'Z'

bits :: [Bit] -> Doc
bits = doubleQuotes . text . map bit_char

expr_lit :: Maybe Size -> ExprLit -> Doc
expr_lit Nothing (ExprNum i)          = int $ fromIntegral i
expr_lit (Just sz) (ExprNum i)        = bits (to_bits sz i)
expr_lit _ (ExprBit x)                = quotes (char (bit_char x))
                                        -- ok to ignore the size here?
expr_lit Nothing (ExprBitVector xs)   = bits xs
expr_lit (Just sz) (ExprBitVector xs) = bits $ take sz xs

expr :: Expr -> Doc
expr (ExprLit mb_sz lit) = expr_lit mb_sz lit
expr (ExprVar n) = text n
expr (ExprIndex s i) = text s <> parens (expr i)
expr (ExprSlice s h l)
  | h >= l = text s <> parens (expr h <+> text "downto" <+> expr l)
  | otherwise = text s <> parens (expr h <+> text "to" <+> expr l)

expr (ExprConcat ss) = hcat $ punctuate (text " & ") (map expr ss)
expr (ExprUnary op e) = lookupUnary op (expr e)
expr (ExprBinary op a b) = lookupBinary op (expr a) (expr b)
expr (ExprFunCall f args) = text f <> parens (cat $ punctuate comma $ map expr args)
expr (ExprCond c t e) = expr t <+> text "when" <+> expr c <+> text "else" $$ expr e
expr (ExprCase _ [] Nothing) = error "VHDL does not support non-defaulted ExprCase"
expr (ExprCase _ [] (Just e)) = expr e
expr (ExprCase e (([],_):alts) def) = expr (ExprCase e alts def)
expr (ExprCase e ((p:ps,alt):alts) def) =
    expr (ExprCond (ExprBinary Equals e p) alt (ExprCase e ((ps,alt):alts) def))
expr x = text (show x)


lookupUnary :: UnaryOp -> Doc -> Doc
lookupUnary op e = text (unOp op) <> parens e

unOp :: UnaryOp -> String
unOp UPlus = ""
unOp UMinus = "-"
unOp LNeg = "not"
unOp UAnd = "and"
unOp UNand = "nand"
unOp UOr = "or"
unOp UNor = "nor"
unOp UXor = "xor"
unOp UXnor = "xnor"
unOp Neg = "-"


-- "(\\(.*\\), text \\(.*\\)),"
lookupBinary :: BinaryOp -> Doc -> Doc -> Doc
lookupBinary op a b = parens $ a <+> text (binOp op) <+> b

binOp :: BinaryOp -> String
binOp Pow = "**"
binOp Plus = "+"
binOp Minus = "-"
binOp Times = "*"
binOp Divide = "/"
binOp Modulo = "mod"
binOp Equals = "="
binOp NotEquals = "!="
binOp CEquals = "="
binOp CNotEquals = "!="
binOp LAnd = "and"
binOp LOr = "or"
binOp LessThan = "<"
binOp LessEqual = "<="
binOp GreaterThan = ">"
binOp GreaterEqual = ">="
binOp And = "and"
binOp Nand = "nand"
binOp Or = "or"
binOp Nor = "nor"
binOp Xor = "xor"
binOp Xnor = "xnor"
binOp ShiftLeft = "sll"
binOp ShiftRight = "srl"
binOp RotateLeft = "rol"
binOp RotateRight = "ror"
binOp ShiftLeftArith = "sla"
binOp ShiftRightArith = "sra"

slv_type :: Maybe Range -> Doc
slv_type Nothing = text "std_logic"
slv_type (Just r) =  text "std_logic_vector" <> range r

range :: Range -> Doc
range (Range high low) = parens (expr high <+> text "downto" <+> expr low)
