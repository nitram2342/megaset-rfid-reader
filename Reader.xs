#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "const-c.inc"

MODULE = RFID::Reader		PACKAGE = RFID::Reader		

INCLUDE: const-xs.inc
