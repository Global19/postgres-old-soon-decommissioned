/*-------------------------------------------------------------------------
 *
 * nodeSubqueryscan.h
 *
 *
 *
 * Portions Copyright (c) 1996-2002, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * $Id$
 *
 *-------------------------------------------------------------------------
 */
#ifndef NODESUBQUERYSCAN_H
#define NODESUBQUERYSCAN_H

#include "nodes/plannodes.h"

extern TupleTableSlot *ExecSubqueryScan(SubqueryScan *node);
extern void ExecEndSubqueryScan(SubqueryScan *node);
extern bool ExecInitSubqueryScan(SubqueryScan *node, EState *estate, Plan *parent);
extern int	ExecCountSlotsSubqueryScan(SubqueryScan *node);
extern void ExecSubqueryReScan(SubqueryScan *node, ExprContext *exprCtxt, Plan *parent);

#endif   /* NODESUBQUERYSCAN_H */
