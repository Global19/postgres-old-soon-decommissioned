/*-------------------------------------------------------------------------
 *
 * setrefs.c
 *	  Routines to change varno/attno entries to contain references
 *
 * Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  $Header$
 *
 *-------------------------------------------------------------------------
 */
#include <sys/types.h>

#include "postgres.h"

#include "nodes/pg_list.h"
#include "nodes/plannodes.h"
#include "nodes/primnodes.h"
#include "nodes/relation.h"

#include "utils/elog.h"
#include "nodes/nodeFuncs.h"
#include "nodes/makefuncs.h"

#include "optimizer/internal.h"
#include "optimizer/clauses.h"
#include "optimizer/restrictinfo.h"
#include "optimizer/keys.h"
#include "optimizer/planmain.h"
#include "optimizer/tlist.h"
#include "optimizer/var.h"
#include "optimizer/tlist.h"

static void set_join_tlist_references(Join *join);
static void set_nonamescan_tlist_references(SeqScan *nonamescan);
static void set_noname_tlist_references(Noname *noname);
static List *replace_clause_joinvar_refs(Expr *clause,
							List *outer_tlist, List *inner_tlist);
static List *replace_subclause_joinvar_refs(List *clauses,
							   List *outer_tlist, List *inner_tlist);
static Var *replace_joinvar_refs(Var *var, List *outer_tlist, List *inner_tlist);
static List *tlist_noname_references(Oid nonameid, List *tlist);
static void replace_result_clause(Node *clause, List *subplanTargetList);
static bool OperandIsInner(Node *opnd, int inner_relid);
static List *replace_agg_clause(Node *expr, List *targetlist);
static Node *del_agg_clause(Node *clause);
static void set_result_tlist_references(Result *resultNode);

/*****************************************************************************
 *
 *		SUBPLAN REFERENCES
 *
 *****************************************************************************/

/*
 * set_tlist_references
 *	  Modifies the target list of nodes in a plan to reference target lists
 *	  at lower levels.
 *
 * 'plan' is the plan whose target list and children's target lists will
 *		be modified
 *
 * Returns nothing of interest, but modifies internal fields of nodes.
 *
 */
void
set_tlist_references(Plan *plan)
{
	if (plan == NULL)
		return;

	if (IsA_Join(plan))
		set_join_tlist_references((Join *) plan);
	else if (IsA(plan, SeqScan) &&plan->lefttree &&
			 IsA_Noname(plan->lefttree))
		set_nonamescan_tlist_references((SeqScan *) plan);
	else if (IsA(plan, Sort))
		set_noname_tlist_references((Noname *) plan);
	else if (IsA(plan, Result))
		set_result_tlist_references((Result *) plan);
	else if (IsA(plan, Hash))
		set_tlist_references(plan->lefttree);
}

/*
 * set_join_tlist_references
 *	  Modifies the target list of a join node by setting the varnos and
 *	  varattnos to reference the target list of the outer and inner join
 *	  relations.
 *
 *	  Creates a target list for a join node to contain references by setting
 *	  varno values to OUTER or INNER and setting attno values to the
 *	  result domain number of either the corresponding outer or inner join
 *	  tuple.
 *
 * 'join' is a join plan node
 *
 * Returns nothing of interest, but modifies internal fields of nodes.
 *
 */
static void
set_join_tlist_references(Join *join)
{
	Plan	   *outer = ((Plan *) join)->lefttree;
	Plan	   *inner = ((Plan *) join)->righttree;
	List	   *new_join_targetlist = NIL;
	TargetEntry *temp = (TargetEntry *) NULL;
	List	   *entry = NIL;
	List	   *inner_tlist = NULL;
	List	   *outer_tlist = NULL;
	TargetEntry *xtl = (TargetEntry *) NULL;
	List	   *qptlist = ((Plan *) join)->targetlist;

	foreach(entry, qptlist)
	{
		List	   *joinvar;

		xtl = (TargetEntry *) lfirst(entry);
		inner_tlist = ((inner == NULL) ? NIL : inner->targetlist);
		outer_tlist = ((outer == NULL) ? NIL : outer->targetlist);
		joinvar = replace_clause_joinvar_refs((Expr *) get_expr(xtl),
											  outer_tlist,
											  inner_tlist);

		temp = makeTargetEntry(xtl->resdom, (Node *) joinvar);
		new_join_targetlist = lappend(new_join_targetlist, temp);
	}

	((Plan *) join)->targetlist = new_join_targetlist;
	if (outer != NULL)
		set_tlist_references(outer);
	if (inner != NULL)
		set_tlist_references(inner);
}

/*
 * set_nonamescan_tlist_references
 *	  Modifies the target list of a node that scans a noname relation (i.e., a
 *	  sort or hash node) so that the varnos refer to the child noname.
 *
 * 'nonamescan' is a seqscan node
 *
 * Returns nothing of interest, but modifies internal fields of nodes.
 *
 */
static void
set_nonamescan_tlist_references(SeqScan *nonamescan)
{
	Noname	   *noname = (Noname *) ((Plan *) nonamescan)->lefttree;

	((Plan *) nonamescan)->targetlist = tlist_noname_references(noname->nonameid,
							  ((Plan *) nonamescan)->targetlist);
	set_noname_tlist_references(noname);
}

/*
 * set_noname_tlist_references
 *	  The noname's vars are made consistent with (actually, identical to) the
 *	  modified version of the target list of the node from which noname node
 *	  receives its tuples.
 *
 * 'noname' is a noname (e.g., sort, hash) plan node
 *
 * Returns nothing of interest, but modifies internal fields of nodes.
 *
 */
static void
set_noname_tlist_references(Noname *noname)
{
	Plan	   *source = ((Plan *) noname)->lefttree;

	if (source != NULL)
	{
		set_tlist_references(source);
		((Plan *) noname)->targetlist = copy_vars(((Plan *) noname)->targetlist,
					  (source)->targetlist);
	}
	else
		elog(ERROR, "calling set_noname_tlist_references with empty lefttree");
}

/*
 * join_references
 *	   Creates a new set of join clauses by replacing the varno/varattno
 *	   values of variables in the clauses to reference target list values
 *	   from the outer and inner join relation target lists.
 *
 * 'clauses' is the list of join clauses
 * 'outer_tlist' is the target list of the outer join relation
 * 'inner_tlist' is the target list of the inner join relation
 *
 * Returns the new join clauses.
 *
 */
List *
join_references(List *clauses,
				List *outer_tlist,
				List *inner_tlist)
{
	return (replace_subclause_joinvar_refs(clauses,
										   outer_tlist,
										   inner_tlist));
}

/*
 * index_outerjoin_references
 *	  Given a list of join clauses, replace the operand corresponding to the
 *	  outer relation in the join with references to the corresponding target
 *	  list element in 'outer_tlist' (the outer is rather obscurely
 *	  identified as the side that doesn't contain a var whose varno equals
 *	  'inner_relid').
 *
 *	  As a side effect, the operator is replaced by the regproc id.
 *
 * 'inner_indxqual' is the list of join clauses (so-called because they
 * are used as qualifications for the inner (inbex) scan of a nestloop)
 *
 * Returns the new list of clauses.
 *
 */
List *
index_outerjoin_references(List *inner_indxqual,
						   List *outer_tlist,
						   Index inner_relid)
{
	List	   *t_list = NIL;
	Expr	   *temp = NULL;
	List	   *t_clause = NIL;
	Expr	   *clause = NULL;

	foreach(t_clause, inner_indxqual)
	{
		clause = lfirst(t_clause);

		/*
		 * if inner scan on the right.
		 */
		if (OperandIsInner((Node *) get_rightop(clause), inner_relid))
		{
			Var		   *joinvar = (Var *)
			replace_clause_joinvar_refs((Expr *) get_leftop(clause),
										outer_tlist,
										NIL);

			temp = make_opclause(replace_opid((Oper *) ((Expr *) clause)->oper),
								 joinvar,
								 get_rightop(clause));
			t_list = lappend(t_list, temp);
		}
		else
		{
			/* inner scan on left */
			Var		   *joinvar = (Var *)
			replace_clause_joinvar_refs((Expr *) get_rightop(clause),
										outer_tlist,
										NIL);

			temp = make_opclause(replace_opid((Oper *) ((Expr *) clause)->oper),
								 get_leftop(clause),
								 joinvar);
			t_list = lappend(t_list, temp);
		}

	}
	return t_list;
}

/*
 * replace_clause_joinvar_refs
 * replace_subclause_joinvar_refs
 * replace_joinvar_refs
 *
 *	  Replaces all variables within a join clause with a new var node
 *	  whose varno/varattno fields contain a reference to a target list
 *	  element from either the outer or inner join relation.
 *
 * 'clause' is the join clause
 * 'outer_tlist' is the target list of the outer join relation
 * 'inner_tlist' is the target list of the inner join relation
 *
 * Returns the new join clause.
 *
 */
static List *
replace_clause_joinvar_refs(Expr *clause,
							List *outer_tlist,
							List *inner_tlist)
{
	List	   *temp = NULL;

	if (clause == NULL)
		return NULL;
	if (IsA(clause, Var))
	{
		temp = (List *) replace_joinvar_refs((Var *) clause,
											 outer_tlist, inner_tlist);
		if (temp != NULL)
			return temp;
		else if (clause != NULL)
			return (List *) clause;
		else
			return NIL;
	}
	else if (single_node((Node *) clause))
		return (List *) clause;
	else if (and_clause((Node *) clause))
	{
		List	   *andclause = replace_subclause_joinvar_refs(((Expr *) clause)->args,
									   outer_tlist,
									   inner_tlist);

		return (List *) make_andclause(andclause);
	}
	else if (or_clause((Node *) clause))
	{
		List	   *orclause = replace_subclause_joinvar_refs(((Expr *) clause)->args,
									   outer_tlist,
									   inner_tlist);

		return (List *) make_orclause(orclause);
	}
	else if (IsA(clause, ArrayRef))
	{
		ArrayRef   *aref = (ArrayRef *) clause;

		temp = replace_subclause_joinvar_refs(aref->refupperindexpr,
											  outer_tlist,
											  inner_tlist);
		aref->refupperindexpr = (List *) temp;
		temp = replace_subclause_joinvar_refs(aref->reflowerindexpr,
											  outer_tlist,
											  inner_tlist);
		aref->reflowerindexpr = (List *) temp;
		temp = replace_clause_joinvar_refs((Expr *) aref->refexpr,
										   outer_tlist,
										   inner_tlist);
		aref->refexpr = (Node *) temp;

		/*
		 * no need to set refassgnexpr.  we only set that in the target
		 * list on replaces, and this is an array reference in the
		 * qualification.  if we got this far, it's 0x0 in the ArrayRef
		 * structure 'clause'.
		 */

		return (List *) clause;
	}
	else if (is_funcclause((Node *) clause))
	{
		List	   *funcclause = replace_subclause_joinvar_refs(((Expr *) clause)->args,
									   outer_tlist,
									   inner_tlist);

		return ((List *) make_funcclause((Func *) ((Expr *) clause)->oper,
										 funcclause));
	}
	else if (not_clause((Node *) clause))
	{
		List	   *notclause = replace_clause_joinvar_refs(get_notclausearg(clause),
									outer_tlist,
									inner_tlist);

		return (List *) make_notclause((Expr *) notclause);
	}
	else if (is_opclause((Node *) clause))
	{
		Var		   *leftvar = (Var *) replace_clause_joinvar_refs((Expr *) get_leftop(clause),
											outer_tlist,
											inner_tlist);
		Var		   *rightvar = (Var *) replace_clause_joinvar_refs((Expr *) get_rightop(clause),
											outer_tlist,
											inner_tlist);

		return ((List *) make_opclause(replace_opid((Oper *) ((Expr *) clause)->oper),
									   leftvar,
									   rightvar));
	}
	else if (is_subplan(clause))
	{
		((Expr *) clause)->args = replace_subclause_joinvar_refs(((Expr *) clause)->args,
										   outer_tlist,
										   inner_tlist);
		((SubPlan *) ((Expr *) clause)->oper)->sublink->oper =
			replace_subclause_joinvar_refs(((SubPlan *) ((Expr *) clause)->oper)->sublink->oper,
										   outer_tlist,
										   inner_tlist);
		return (List *) clause;
	}
	else if (IsA(clause, CaseExpr))
	{
		((CaseExpr *) clause)->args =
			(List *) replace_subclause_joinvar_refs(((CaseExpr *) clause)->args,
													outer_tlist,
													inner_tlist);

		((CaseExpr *) clause)->defresult =
			(Node *) replace_clause_joinvar_refs((Expr *) ((CaseExpr *) clause)->defresult,
												 outer_tlist,
												 inner_tlist);
		return (List *) clause;
	}
	else if (IsA(clause, CaseWhen))
	{
		((CaseWhen *) clause)->expr =
			(Node *) replace_clause_joinvar_refs((Expr *) ((CaseWhen *) clause)->expr,
												 outer_tlist,
												 inner_tlist);

		((CaseWhen *) clause)->result =
			(Node *) replace_clause_joinvar_refs((Expr *) ((CaseWhen *) clause)->result,
												 outer_tlist,
												 inner_tlist);
		return (List *) clause;
	}

	/* shouldn't reach here */
	elog(ERROR, "replace_clause_joinvar_refs: unsupported clause %d",
		 nodeTag(clause));
	return NULL;
}

static List *
replace_subclause_joinvar_refs(List *clauses,
							   List *outer_tlist,
							   List *inner_tlist)
{
	List	   *t_list = NIL;
	List	   *temp = NIL;
	List	   *clause = NIL;

	foreach(clause, clauses)
	{
		temp = replace_clause_joinvar_refs(lfirst(clause),
										   outer_tlist,
										   inner_tlist);
		t_list = lappend(t_list, temp);
	}
	return t_list;
}

static Var *
replace_joinvar_refs(Var *var, List *outer_tlist, List *inner_tlist)
{
	Resdom	   *outer_resdom = (Resdom *) NULL;

	outer_resdom = tlist_member(var, outer_tlist);

	if (outer_resdom != NULL && IsA(outer_resdom, Resdom))
	{
		return (makeVar(OUTER,
						outer_resdom->resno,
						var->vartype,
						var->vartypmod,
						0,
						var->varnoold,
						var->varoattno));
	}
	else
	{
		Resdom	   *inner_resdom;

		inner_resdom = tlist_member(var, inner_tlist);
		if (inner_resdom != NULL && IsA(inner_resdom, Resdom))
		{
			return (makeVar(INNER,
							inner_resdom->resno,
							var->vartype,
							var->vartypmod,
							0,
							var->varnoold,
							var->varoattno));
		}
	}
	return (Var *) NULL;
}

/*
 * tlist_noname_references
 *	  Creates a new target list for a node that scans a noname relation,
 *	  setting the varnos to the id of the noname relation and setting varids
 *	  if necessary (varids are only needed if this is a targetlist internal
 *	  to the tree, in which case the targetlist entry always contains a var
 *	  node, so we can just copy it from the noname).
 *
 * 'nonameid' is the id of the noname relation
 * 'tlist' is the target list to be modified
 *
 * Returns new target list
 *
 */
static List *
tlist_noname_references(Oid nonameid,
					  List *tlist)
{
	List	   *t_list = NIL;
	TargetEntry *noname = (TargetEntry *) NULL;
	TargetEntry *xtl = NULL;
	List	   *entry;

	foreach(entry, tlist)
	{
		AttrNumber	oattno;

		xtl = lfirst(entry);
		if (IsA(get_expr(xtl), Var))
			oattno = ((Var *) xtl->expr)->varoattno;
		else
			oattno = 0;

		noname = makeTargetEntry(xtl->resdom,
							   (Node *) makeVar(nonameid,
												xtl->resdom->resno,
												xtl->resdom->restype,
												xtl->resdom->restypmod,
												0,
												nonameid,
												oattno));

		t_list = lappend(t_list, noname);
	}
	return t_list;
}

/*---------------------------------------------------------
 *
 * set_result_tlist_references
 *
 * Change the target list of a Result node, so that it correctly
 * addresses the tuples returned by its left tree subplan.
 *
 * NOTE:
 *	1) we ignore the right tree! (in the current implementation
 *	   it is always nil
 *	2) this routine will probably *NOT* work with nested dot
 *	   fields....
 */
static void
set_result_tlist_references(Result *resultNode)
{
	Plan	   *subplan;
	List	   *resultTargetList;
	List	   *subplanTargetList;
	List	   *t;
	TargetEntry *entry;
	Expr	   *expr;

	resultTargetList = ((Plan *) resultNode)->targetlist;

	/*
	 * NOTE: we only consider the left tree subplan. This is usually a seq
	 * scan.
	 */
	subplan = ((Plan *) resultNode)->lefttree;
	if (subplan != NULL)
		subplanTargetList = subplan->targetlist;
	else
		subplanTargetList = NIL;

	/*
	 * now for traverse all the entris of the target list. These should be
	 * of the form (Resdom_Node Expression). For every expression clause,
	 * call "replace_result_clause()" to appropriatelly change all the Var
	 * nodes.
	 */
	foreach(t, resultTargetList)
	{
		entry = (TargetEntry *) lfirst(t);
		expr = (Expr *) get_expr(entry);
		replace_result_clause((Node *) expr, subplanTargetList);
	}
}

/*---------------------------------------------------------
 *
 * replace_result_clause
 *
 * This routine is called from set_result_tlist_references().
 * and modifies the expressions of the target list of a Result
 * node so that all Var nodes reference the target list of its subplan.
 *
 */
static void
replace_result_clause(Node *clause,
					  List *subplanTargetList)	/* target list of the
												 * subplan */
{
	List	   *t;

	if (clause == NULL)
		return;
	if (IsA(clause, Var))
	{
		TargetEntry *subplanVar;

		/*
		 * Ha! A Var node!
		 */
		subplanVar = match_varid((Var *) clause, subplanTargetList);

		/*
		 * Change the varno & varattno fields of the var node.
		 *
		 */
		((Var *) clause)->varno = (Index) OUTER;
		((Var *) clause)->varattno = subplanVar->resdom->resno;
	}
	else if (IsA(clause, Aggref))
		replace_result_clause(((Aggref *) clause)->target, subplanTargetList);
	else if (is_funcclause(clause))
	{
		List	   *subExpr;

		/*
		 * This is a function. Recursively call this routine for its
		 * arguments...
		 */
		subExpr = ((Expr *) clause)->args;
		foreach(t, subExpr)
			replace_result_clause(lfirst(t), subplanTargetList);
	}
	else if (IsA(clause, ArrayRef))
	{
		ArrayRef   *aref = (ArrayRef *) clause;

		/*
		 * This is an arrayref. Recursively call this routine for its
		 * expression and its index expression...
		 */
		foreach(t, aref->refupperindexpr)
			replace_result_clause(lfirst(t), subplanTargetList);
		foreach(t, aref->reflowerindexpr)
			replace_result_clause(lfirst(t), subplanTargetList);
		replace_result_clause(aref->refexpr,
							  subplanTargetList);
		replace_result_clause(aref->refassgnexpr,
							  subplanTargetList);
	}
	else if (is_opclause(clause))
	{
		Node	   *subNode;

		/*
		 * This is an operator. Recursively call this routine for both its
		 * left and right operands
		 */
		subNode = (Node *) get_leftop((Expr *) clause);
		replace_result_clause(subNode, subplanTargetList);
		subNode = (Node *) get_rightop((Expr *) clause);
		replace_result_clause(subNode, subplanTargetList);
	}
	else if (IsA(clause, Param) ||IsA(clause, Const))
	{
		/* do nothing! */
	}
	else
	{

		/*
		 * Ooops! we can not handle that!
		 */
		elog(ERROR, "replace_result_clause: Can not handle this tlist!\n");
	}
}

static
bool
OperandIsInner(Node *opnd, int inner_relid)
{

	/*
	 * Can be the inner scan if its a varnode or a function and the
	 * inner_relid is equal to the varnode's var number or in the case of
	 * a function the first argument's var number (all args in a
	 * functional index are from the same relation).
	 */
	if (IsA(opnd, Var) &&
		(inner_relid == ((Var *) opnd)->varno))
		return true;
	if (is_funcclause(opnd))
	{
		List	   *firstArg = lfirst(((Expr *) opnd)->args);

		if (IsA(firstArg, Var) &&
			(inner_relid == ((Var *) firstArg)->varno))
			return true;
	}
	return false;
}

/*****************************************************************************
 *
 *****************************************************************************/

/*---------------------------------------------------------
 *
 * set_agg_tlist_references -
 *	  This routine has several responsibilities:
 *	* Update the target list of an Agg node so that it points to
 *	  the tuples returned by its left tree subplan.
 *	* If there is a qual list (from a HAVING clause), similarly update
 *	  vars in it to point to the subplan target list.
 *	* Generate the aggNode->aggs list of Aggref nodes contained in the Agg.
 *
 * The return value is TRUE if all qual clauses include Aggrefs, or FALSE
 * if any do not (caller may choose to raise an error condition).
 */
bool
set_agg_tlist_references(Agg *aggNode)
{
	List	   *subplanTargetList;
	List	   *tl;
	List	   *ql;
	bool		all_quals_ok;

	subplanTargetList = aggNode->plan.lefttree->targetlist;
	aggNode->aggs = NIL;

	foreach(tl, aggNode->plan.targetlist)
	{
		TargetEntry *tle = lfirst(tl);

		aggNode->aggs = nconc(replace_agg_clause(tle->expr, subplanTargetList),
							  aggNode->aggs);
	}

	all_quals_ok = true;
	foreach(ql, aggNode->plan.qual)
	{
		Node *qual = lfirst(ql);
		List *qualaggs = replace_agg_clause(qual, subplanTargetList);
		if (qualaggs == NIL)
			all_quals_ok = false; /* this qual clause has no agg functions! */
		else
			aggNode->aggs = nconc(qualaggs, aggNode->aggs);
	}

	return all_quals_ok;
}

static List *
replace_agg_clause(Node *clause, List *subplanTargetList)
{
	List	   *t;
	List	   *agg_list = NIL;

	if (IsA(clause, Var))
	{
		TargetEntry *subplanVar;

		/*
		 * Ha! A Var node!
		 */
		subplanVar = match_varid((Var *) clause, subplanTargetList);

		/*
		 * Change the varno & varattno fields of the var node.
		 * Note we assume match_varid() will succeed ...
		 *
		 */
		((Var *) clause)->varattno = subplanVar->resdom->resno;

		return NIL;
	}
	else if (is_subplan(clause))
	{
		SubLink *sublink = ((SubPlan *) ((Expr *) clause)->oper)->sublink;

		/*
		 * Only the lefthand side of the sublink should be checked for
		 * aggregates to be attached to the aggs list
		 */
		foreach(t, sublink->lefthand)
			agg_list = nconc(replace_agg_clause(lfirst(t), subplanTargetList),
							 agg_list);
		/* The first argument of ...->oper has also to be checked */
		foreach(t, sublink->oper)
			agg_list = nconc(replace_agg_clause(lfirst(t), subplanTargetList),
							 agg_list);
		return agg_list;
	}
	else if (IsA(clause, Expr))
	{
		/*
		 * Recursively scan the arguments of an expression.
		 * NOTE: this must come after is_subplan() case since
		 * subplan is a kind of Expr node.
		 */
		foreach(t, ((Expr *) clause)->args)
		{
			agg_list = nconc(replace_agg_clause(lfirst(t), subplanTargetList),
							 agg_list);
		}
		return agg_list;
	}
	else if (IsA(clause, Aggref))
	{
		return lcons(clause,
					 replace_agg_clause(((Aggref *) clause)->target,
										subplanTargetList));
	}
	else if (IsA(clause, ArrayRef))
	{
		ArrayRef   *aref = (ArrayRef *) clause;

		/*
		 * This is an arrayref. Recursively call this routine for its
		 * expression and its index expression...
		 */
		foreach(t, aref->refupperindexpr)
			agg_list = nconc(replace_agg_clause(lfirst(t), subplanTargetList),
							 agg_list);
		foreach(t, aref->reflowerindexpr)
			agg_list = nconc(replace_agg_clause(lfirst(t), subplanTargetList),
							 agg_list);
		agg_list = nconc(replace_agg_clause(aref->refexpr, subplanTargetList),
						 agg_list);
		agg_list = nconc(replace_agg_clause(aref->refassgnexpr,
											subplanTargetList),
						 agg_list);
		return agg_list;
	}
	else if (IsA(clause, Param) || IsA(clause, Const))
	{
		/* do nothing! */
		return NIL;
	}
	else
	{
		/*
		 * Ooops! we can not handle that!
		 */
		elog(ERROR, "replace_agg_clause: Cannot handle node type %d",
			 nodeTag(clause));
		return NIL;
	}
}


/*
 * del_agg_tlist_references
 *	  Remove the Agg nodes from the target list
 *	  We do this so inheritance only does aggregates in the upper node
 */
void
del_agg_tlist_references(List *tlist)
{
	List	   *tl;

	foreach(tl, tlist)
	{
		TargetEntry *tle = lfirst(tl);

		tle->expr = del_agg_clause(tle->expr);
	}
}

static Node *
del_agg_clause(Node *clause)
{
	List	   *t;

	if (IsA(clause, Var))
		return clause;
	else if (is_funcclause(clause))
	{

		/*
		 * This is a function. Recursively call this routine for its
		 * arguments...
		 */
		foreach(t, ((Expr *) clause)->args)
			lfirst(t) = del_agg_clause(lfirst(t));
	}
	else if (IsA(clause, Aggref))
	{

		/* here is the real action, to remove the Agg node */
		return del_agg_clause(((Aggref *) clause)->target);

	}
	else if (IsA(clause, ArrayRef))
	{
		ArrayRef   *aref = (ArrayRef *) clause;

		/*
		 * This is an arrayref. Recursively call this routine for its
		 * expression and its index expression...
		 */
		foreach(t, aref->refupperindexpr)
			lfirst(t) = del_agg_clause(lfirst(t));
		foreach(t, aref->reflowerindexpr)
			lfirst(t) = del_agg_clause(lfirst(t));
		aref->refexpr = del_agg_clause(aref->refexpr);
		aref->refassgnexpr = del_agg_clause(aref->refassgnexpr);
	}
	else if (is_opclause(clause))
	{

		/*
		 * This is an operator. Recursively call this routine for both its
		 * left and right operands
		 */
		Node	   *left = (Node *) get_leftop((Expr *) clause);
		Node	   *right = (Node *) get_rightop((Expr *) clause);

		if (left != (Node *) NULL)
			left = del_agg_clause(left);
		if (right != (Node *) NULL)
			right = del_agg_clause(right);
	}
	else if (IsA(clause, Param) ||IsA(clause, Const))
		return clause;
	else
	{

		/*
		 * Ooops! we can not handle that!
		 */
		elog(ERROR, "del_agg_clause: Can not handle this tlist!\n");
	}
	return NULL;
}

/*
 * check_having_qual_for_vars takes the havingQual and the actual targetlist
 * as arguments and recursively scans the havingQual for attributes that are
 * not included in the targetlist yet.  This will occur with queries like:
 *
 * SELECT sid FROM part GROUP BY sid HAVING MIN(pid) > 1;
 *
 * To be able to handle queries like that correctly we have to extend the
 * actual targetlist (which will be the one used for the GROUP node later on)
 * by these attributes.  The return value is the extended targetlist.
 */
List *
check_having_qual_for_vars(Node *clause, List *targetlist_so_far)
{
	List	   *t;

	if (IsA(clause, Var))
	{
		RelOptInfo	tmp_rel;

		/*
		 * Ha! A Var node!
		 */

		tmp_rel.targetlist = targetlist_so_far;

		/* Check if the VAR is already contained in the targetlist */
		if (tlist_member((Var *) clause, (List *) targetlist_so_far) == NULL)
			add_var_to_tlist(&tmp_rel, (Var *) clause);

		return tmp_rel.targetlist;
	}
	else if (IsA(clause, Expr) && ! is_subplan(clause))
	{
		/*
		 * Recursively scan the arguments of an expression.
		 */
		foreach(t, ((Expr *) clause)->args)
			targetlist_so_far = check_having_qual_for_vars(lfirst(t), targetlist_so_far);
		return targetlist_so_far;
	}
	else if (IsA(clause, Aggref))
	{
		targetlist_so_far = check_having_qual_for_vars(((Aggref *) clause)->target, targetlist_so_far);
		return targetlist_so_far;
	}
	else if (IsA(clause, ArrayRef))
	{
		ArrayRef   *aref = (ArrayRef *) clause;

		/*
		 * This is an arrayref. Recursively call this routine for its
		 * expression and its index expression...
		 */
		foreach(t, aref->refupperindexpr)
			targetlist_so_far = check_having_qual_for_vars(lfirst(t), targetlist_so_far);
		foreach(t, aref->reflowerindexpr)
			targetlist_so_far = check_having_qual_for_vars(lfirst(t), targetlist_so_far);
		targetlist_so_far = check_having_qual_for_vars(aref->refexpr, targetlist_so_far);
		targetlist_so_far = check_having_qual_for_vars(aref->refassgnexpr, targetlist_so_far);

		return targetlist_so_far;
	}
	else if (IsA(clause, Param) || IsA(clause, Const))
	{
		/* do nothing! */
		return targetlist_so_far;
	}
	/*
	 * If we get to a sublink, then we only have to check the lefthand
	 * side of the expression to see if there are any additional VARs.
	 * QUESTION: can this code actually be hit?
	 */
	else if (IsA(clause, SubLink))
	{
		foreach(t, ((SubLink *) clause)->lefthand)
			targetlist_so_far = check_having_qual_for_vars(lfirst(t), targetlist_so_far);
		return targetlist_so_far;
	}
	else
	{
		/*
		 * Ooops! we can not handle that!
		 */
		elog(ERROR, "check_having_qual_for_vars: Cannot handle node type %d",
			 nodeTag(clause));
		return NIL;
	}
}

/*
 * check_having_for_ungrouped_vars takes the havingQual and the list of
 * GROUP BY clauses and checks for subplans in the havingQual that are being
 * passed ungrouped variables as parameters.  In other contexts, ungrouped
 * vars in the havingQual will be detected by the parser (see parse_agg.c,
 * exprIsAggOrGroupCol()).  But that routine currently does not check subplans,
 * because the necessary info is not computed until the planner runs.
 * This ought to be cleaned up someday.
 *
 * NOTE: the havingClause has been cnf-ified, so AND subclauses have been
 * turned into a plain List.  Thus, this routine has to cope with List nodes
 * where the routine above does not...
 */

void
check_having_for_ungrouped_vars(Node *clause, List *groupClause)
{
	List	   *t;

	if (IsA(clause, Var))
	{
		/* Ignore vars elsewhere in the having clause, since the
		 * parser already checked 'em.
		 */
	}
	else if (is_subplan(clause))
	{
		/*
		 * The args list of the subplan node represents attributes from outside
		 * passed into the sublink.
		 */
		foreach(t, ((Expr *) clause)->args)
		{
			bool contained_in_group_clause = false;
			List	   *gl;

			foreach(gl, groupClause)
			{
				if (var_equal(lfirst(t),
							  get_expr(((GroupClause *) lfirst(gl))->entry)))
				{
					contained_in_group_clause = true;
					break;
				}
			}

			if (!contained_in_group_clause)
				elog(ERROR, "Sub-SELECT in HAVING clause must use only GROUPed attributes from outer SELECT");
		}
	}
	else if (IsA(clause, Expr))
	{
		/*
		 * Recursively scan the arguments of an expression.
		 * NOTE: this must come after is_subplan() case since
		 * subplan is a kind of Expr node.
		 */
		foreach(t, ((Expr *) clause)->args)
			check_having_for_ungrouped_vars(lfirst(t), groupClause);
	}
	else if (IsA(clause, List))
	{
		/*
		 * Recursively scan AND subclauses (see NOTE above).
		 */
		foreach(t, ((List *) clause))
			check_having_for_ungrouped_vars(lfirst(t), groupClause);
	}
	else if (IsA(clause, Aggref))
	{
			check_having_for_ungrouped_vars(((Aggref *) clause)->target,
											groupClause);
	}
	else if (IsA(clause, ArrayRef))
	{
		ArrayRef   *aref = (ArrayRef *) clause;

		/*
		 * This is an arrayref. Recursively call this routine for its
		 * expression and its index expression...
		 */
		foreach(t, aref->refupperindexpr)
			check_having_for_ungrouped_vars(lfirst(t), groupClause);
		foreach(t, aref->reflowerindexpr)
			check_having_for_ungrouped_vars(lfirst(t), groupClause);
		check_having_for_ungrouped_vars(aref->refexpr, groupClause);
		check_having_for_ungrouped_vars(aref->refassgnexpr, groupClause);
	}
	else if (IsA(clause, Param) || IsA(clause, Const))
	{
		/* do nothing! */
	}
	else
	{
		/*
		 * Ooops! we can not handle that!
		 */
		elog(ERROR, "check_having_for_ungrouped_vars: Cannot handle node type %d",
			 nodeTag(clause));
	}
}
