--------------------------------------------------------------------------------
-- |
-- Module       :  Language.Netlist.GenVerilog
-- Copyright    :  (c) Signali Corp. 2010
-- License      :  All rights reserved
--
-- Maintainer   : pweaver@signalicorp.com
-- Stability    : experimental
-- Portability  : non-portable (DeriveDataTypeable)
--
-- Translate a Netlist AST into a Verilog AST.
--
-- The @netlist@ package defines the Netlist AST and the @verilog@ package
-- defines the Verilog AST.
--
-- Not every Netlist AST is compatible with Verilog.  For example, the Netlist
-- AST permits left- and right-rotate operators, which are not supported in
-- Verilog.
--------------------------------------------------------------------------------
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -Wall #-}

-- TODO: endianness - currently we're hardcoded to little endian verilog

module Language.Netlist.GenVerilog ( mk_module
                                   , mk_decl
                                   , mk_stmt
                                   , mk_expr
                                   ) where

import Numeric          ( showIntAtBase )

import Language.Netlist.AST
import qualified Language.Verilog.Syntax as V

-- -----------------------------------------------------------------------------

mk_module :: Module -> V.Module
mk_module (Module name ins outs statics decls)
  = V.Module (mk_ident name) ports items
  where
    params= [ V.ParamDeclItem (V.ParamDecl [V.ParamAssign (mk_ident x) (mk_expr expr)])
              | (x, expr) <- statics
            ]
    ports = map (mk_ident . fst) ins ++ map (mk_ident . fst) outs
    items = [ V.InputDeclItem (V.InputDecl (fmap mk_range mb_range) [mk_ident x])
              | (x, mb_range) <- ins ] ++

            [ V.OutputDeclItem (V.OutputDecl (fmap mk_range mb_range) [mk_ident x])
              | (x, mb_range) <- outs ] ++

            params ++
            concatMap mk_decl decls


mk_decl :: Decl -> [V.Item]
mk_decl (NetDecl x mb_range mb_expr)
  = [V.NetDeclItem decl]
  where
    mb_range' = fmap (V.SimpleRange . mk_range) mb_range
    decl = case mb_expr of
             Nothing   -> V.NetDecl V.Net_wire mb_range' Nothing [mk_ident x]
             Just expr -> V.NetDeclAssign V.Net_wire Nothing mb_range' Nothing
                          [(mk_ident x, mk_expr expr)]

mk_decl (NetAssign x expr)
  = [V.AssignItem Nothing Nothing [mkAssign x expr]]

mk_decl (MemDecl x mb_range1 mb_range2 startMb)
  = [V.RegDeclItem (V.RegDecl V.Reg_reg (fmap mk_range mb_range2)
                    [case mb_range1 of
                       Nothing -> V.RegVar (mk_ident x) (fmap mk_exprs startMb)
                       Just r  -> V.MemVar (mk_ident x) (mk_range r)
                    ])]
 where
   mk_exprs :: [Expr] -> V.Expression
   mk_exprs [e] = mk_expr e
   mk_exprs es  = mk_expr (ExprConcat es)

mk_decl (InstDecl mod_name inst_name params inputs outputs)
  = [V.InstanceItem (V.Instance (mk_ident mod_name) v_params [inst])]
  where
    v_params  = Right [ V.Parameter (mk_ident x) (mk_expr expr)
                        | (x, expr) <- params ]
    inst      = V.Inst (mk_ident inst_name) Nothing (V.NamedConnections cs)
    cs        = [ V.NamedConnection (mk_ident x) (mk_expr expr)
                  | (x, expr) <- inputs ++ outputs ]

mk_decl (InitProcessDecl stmt)
  = [V.InitialItem (mk_stmt stmt)]

mk_decl (CommentDecl str)
  = [V.CommentItem str]

mk_decl (ProcessDecl (Event (mk_expr -> clk) edge) Nothing stmt)
  = [V.AlwaysItem (V.EventControlStmt e (Just s))]
  where
    e = V.EventControlExpr event
    s = mk_stmt stmt
    (event, _) = edge_helper edge clk
    -- conal: simplified from below, removing redundant (I think) conditional.
    -- s = V.IfStmt cond (Just (mk_stmt stmt)) Nothing
    -- (event, cond) = edge_helper edge clk

mk_decl (ProcessDecl (Event (mk_expr -> clk) clk_edge)
         (Just (Event (mk_expr -> reset) reset_edge, reset_stmt)) stmt)
  = [V.AlwaysItem (V.EventControlStmt e (Just s1))]
  where
    e = V.EventControlExpr (V.EventOr clk_event reset_event)
    s1    = V.IfStmt reset_cond (Just (mk_stmt reset_stmt)) (Just s2)
    s2    = V.IfStmt clk_cond   (Just (mk_stmt stmt)) Nothing
    (clk_event, clk_cond) = edge_helper clk_edge clk
    (reset_event, reset_cond) = edge_helper reset_edge reset

mk_decl decl =
  error ("Language.Netlist.GenVerilog.mk_decl: unexpected decl "
         ++ show decl)

edge_helper :: Edge -> V.Expression -> (V.EventExpr, V.Expression)
edge_helper PosEdge x = (V.EventPosedge x, x)
edge_helper NegEdge x = (V.EventNegedge x, V.ExprUnary V.UBang x)

mk_range :: Range -> V.Range
mk_range (Range e1 e2)
  = V.Range (mk_expr e1) (mk_expr e2)

mk_stmt :: Stmt -> V.Statement
mk_stmt (Assign x expr)
  = V.NonBlockingAssignment (mk_expr x) Nothing (mk_expr expr)
mk_stmt (If cond s1 mb_s2)
  = V.IfStmt (mk_expr cond) (Just (mk_stmt s1)) (fmap mk_stmt mb_s2)
mk_stmt (Case e case_items mb_default)
  = V.CaseStmt V.Case (mk_expr e) $
    [ V.CaseItem (map mk_expr es) (Just (mk_stmt stmt))
      | (es, stmt) <- case_items ]
    ++
    case mb_default of
      Just stmt -> [V.CaseDefault (Just (mk_stmt stmt))]
      Nothing   -> []
mk_stmt (Seq stmts)
  = V.SeqBlock Nothing [] (map mk_stmt stmts)
mk_stmt (FunCallStmt x es)
  | head x == '$'
  = V.TaskStmt (mk_ident (tail x)) (Just (map mk_expr es))
  | otherwise
  = error ("FunCallStmt " ++ x)

mk_lit :: Maybe Size -> ExprLit -> V.Number
-- | A real number: sign, integral integral, fractional part, exponent sign,
-- and exponent value
-- | RealNum (Maybe Sign) String (Maybe String) (Maybe (Maybe Sign, String))
-- data Sign
--   = Pos | Neg
-- mk_lit mb_sz (ExprFloat x) = V.RealNum sn int frac es ev
mk_lit mb_sz (ExprFloat x) = V.RealNum sn (show int) frac Nothing
  where  sn  | x < 0.0   = Just V.Neg
             | otherwise = Nothing
         int | x < 0.0   = abs $ floor x + 1
             | otherwise = floor x
         frac            = Just . tail . tail . show $ abs x - (fromIntegral int)

mk_lit mb_sz lit
  = V.IntNum Nothing (fmap show mb_sz) mb_base str
  -- Note that this does not truncate 'str' if its length is more than the size.
  where
    hexdigits = "0123456789abcdef"

    (str, mb_base)
      = case lit of
          ExprNum x
            -> case mb_sz of
                 Just n
                   | n <= 4       -> (showIntAtBase 2 (hexdigits !!) x "", Just V.BinBase)
                   | otherwise    -> (showIntAtBase 16 (hexdigits !!) x "", Just V.HexBase)
                 Nothing          -> (show x, Nothing)
          ExprBit b               -> ([bit_char b], Nothing)
          ExprBitVector bs        -> (map bit_char bs, Just V.BinBase)
          _                       -> error $ "This should never happen!" ++ (show lit)

bit_char :: Bit -> Char
bit_char T = '1'
bit_char F = '0'
bit_char U = 'x'
bit_char Z = 'z'

mk_expr :: Expr -> V.Expression
mk_expr (ExprLit mb_size lit)
  = V.ExprNum $ mk_lit mb_size lit

mk_expr (ExprString x)
  = V.ExprString x
mk_expr (ExprVar x)
  = expr_var x
mk_expr (ExprIndex x e)
  = V.ExprIndex (mk_ident x) (mk_expr e)
mk_expr (ExprSlice x e1 e2)
  = V.ExprSlice (mk_ident x) (mk_expr e1) (mk_expr e2)
mk_expr (ExprSliceOff x e i)
  = f (mk_ident x) (mk_expr e) (V.intExpr (abs i))
  where
    f = if i < 0 then V.ExprSliceMinus else V.ExprSlicePlus
mk_expr (ExprConcat exprs)
  = V.ExprConcat (map mk_expr exprs)
mk_expr (ExprUnary op expr)
  = V.ExprUnary (unary_op op) (mk_expr expr)
mk_expr (ExprBinary op expr1 expr2)
  = V.ExprBinary (binary_op op) (mk_expr expr1) (mk_expr expr2)
mk_expr (ExprCond expr1 expr2 expr3)
  = V.ExprCond (mk_expr expr1) (mk_expr expr2) (mk_expr expr3)
mk_expr (ExprFunCall x es)
  = V.ExprFunCall (mk_ident x) (map mk_expr es)

mk_expr ExprCase{}
  = error "GenVerilog: Not yet supported: ExprCase"

mk_ident :: Ident -> V.Ident
mk_ident x = V.Ident x

expr_var :: Ident -> V.Expression
expr_var x = V.ExprVar (mk_ident x)

mkAssign :: Ident -> Expr -> V.Assignment
mkAssign ident expr
  = V.Assignment (expr_var ident) (mk_expr expr)

unary_op :: UnaryOp -> V.UnaryOp
unary_op UPlus  = V.UPlus
unary_op UMinus = V.UMinus
unary_op LNeg   = V.UBang
unary_op Neg    = V.UTilde
unary_op UAnd   = V.UAnd
unary_op UNand  = V.UNand
unary_op UOr    = V.UOr
unary_op UNor   = V.UNor
unary_op UXor   = V.UXor
unary_op UXnor  = V.UXnor

binary_op :: BinaryOp -> V.BinaryOp
binary_op Pow          = V.Pow
binary_op Plus         = V.Plus
binary_op Minus        = V.Minus
binary_op Times        = V.Times
binary_op Divide       = V.Divide
binary_op Modulo       = V.Modulo
binary_op Equals       = V.Equals
binary_op NotEquals    = V.NotEquals
binary_op CEquals      = V.CEquals
binary_op CNotEquals   = V.CNotEquals
binary_op LAnd         = V.LAnd
binary_op LOr          = V.LOr
binary_op LessThan     = V.LessThan
binary_op LessEqual    = V.LessEqual
binary_op GreaterThan  = V.GreaterThan
binary_op GreaterEqual = V.GreaterEqual
binary_op And          = V.And
binary_op Nand         = V.Nand
binary_op Or           = V.Or
binary_op Nor          = V.Nor
binary_op Xor          = V.Xor
binary_op Xnor         = V.Xnor
binary_op ShiftLeft    = V.ShiftLeft
binary_op ShiftRight   = V.ShiftRight
binary_op RotateLeft   = error "GenVerilog: no left-rotate operator in Verilog"
binary_op RotateRight  = error "GenVerilog: no right-rotate operator in Verilog"

binary_op op =
  error ("Language.Netlist.GenVerilog.binary_op: unexpected op "
         ++ show op)


-- -----------------------------------------------------------------------------
