/*-------------------------------------------------------------------------
 *
 * nodeSetOp.h
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
#ifndef NODESETOP_H
#define NODESETOP_H

#include "nodes/plannodes.h"

extern TupleTableSlot *ExecSetOp(SetOp *node);
extern bool ExecInitSetOp(SetOp *node, EState *estate, Plan *parent);
extern int	ExecCountSlotsSetOp(SetOp *node);
extern void ExecEndSetOp(SetOp *node);
extern void ExecReScanSetOp(SetOp *node, ExprContext *exprCtxt, Plan *parent);

#endif   /* NODESETOP_H */
