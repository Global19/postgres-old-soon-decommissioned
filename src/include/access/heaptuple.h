/*-------------------------------------------------------------------------
 *
 * heaptuple.h--
 *    
 *
 *
 * Copyright (c) 1994, Regents of the University of California
 *
 * $Id$
 *
 *-------------------------------------------------------------------------
 */
#ifndef	HEAPTUPLE_H
#define HEAPTUPLE_H

#include "access/htup.h"
#include "storage/buf.h"
#include "access/tupdesc.h"

extern char *heap_getattr(HeapTuple tup,
                          Buffer b,
                          int attnum,
                          TupleDesc tupleDesc,
                          bool *isnull);

#endif	/* HEAP_TUPLE_H */ 
