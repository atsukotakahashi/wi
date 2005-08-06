#
# yi Makefile
#

TOPDIR = .

include $(TOPDIR)/mk/config.mk

# this rule must remain first
default: boot all

ALL_DIRS=       Yi Yi/Keymap Yi/Keymap/Emacs Yi/Syntax cbits

ifneq "$(CURSES)" ""
ALL_DIRS+=      Yi/Curses
endif

BIN=            yi_
STATIC_BIN=     yi-static

ifeq "$(way)" ""
HS_BINS=        $(BIN) $(STATIC_BIN)
else
HS_BINS=        $(STATIC_BIN)
endif

# Library specific stuff
 
PKG=            yi

# dynamic front end
 
BIN_OBJS=       Boot.o
BIN_DEPS=       plugins posix
BIN_LIBS=       $(LIBS)
HADDOCK_SRCS+=  Boot.hs

# static front end
 
STATIC_OBJS=    Main.$(way_)o
STATIC_BIN_DEPS=yi
STATIC_HC_OPTS  += -package-conf yi.conf -package yi
HADDOCK_SRCS+=  Main.hs

# frontend to the library (by which it is loaded)

FRONTEND_HS_SRC=Yi.hs
LIB_FRONTEND=   Yi.$(way_)o
LIB_IFACE   =   Yi.$(way_)hi
HADDOCK_SRCS+=  $(FRONTEND_HS_SRC)
EXTRA_CLEANS+=	$(LIB_FRONTEND) $(LIB_IFACE)

# Must filter out circular dependencies
NO_DOCS=	Yi/Undo.hs

#
# read in suffix rules
#
include $(TOPDIR)/mk/rules.mk

#
# Special targets (just those in $(TOP))
# 

BIN_HC_OPTS+=     -DLIBDIR=\"$(LIBDIR)\"

#
# Boot is the bootstrap loader. It cant be linked *statically* against -package yi.
#
Boot.o: Boot.hs 
	$(GHC) $(HC_OPTS) $(BIN_HC_OPTS) -main-is Boot.main -c $< -o $@ -ohi $(basename $@).$(way_)hi

#
# Main is the static "loader". It can't get -package-name yi, or it
# won't work in ghci. Could probably filter it out somehow
#
# --make -v0 should be unneccessary, but it seems to allow us to work
# around a bug in ghc 6.5
#
ifneq "$(GLASGOW_HASKELL)" "602"
MAIN_FLAGS=--make -v0
endif

Main.$(way_)o: Main.hs Yi.$(way_)o $(LIBRARY) 
	$(GHC) $(HC_OPTS) $(STATIC_HC_OPTS) $(MAIN_FLAGS) -c $< -o $@

# Break some mutual recursion (why doesn't this work in mk/rules.mk??)
ifneq "$(GLASGOW_HASKELL)" "602"
%.$(way_)hi-boot : %.$(way_)o-boot
	@:
endif

#
# Yi.o is the actual Yi.main, as well as being the frontend of
# the statically linked binary
#
# Semi-magic to defeat <= ghc-6.2.1 use of -i. by default. this stops
# us using a library and it's .o files easily in the same dir -- the
# .o files will always be used over the package dependency. Not an
# issue in ghc-6.2.2. Anyway, the Solution: cd somewhere where -i.
# means nothing.
#
MAGIC_FLAGS   += -package-conf yi.conf -package yi

Yi.$(way_)o: Yi.hs $(LIBRARY) 
	$(GHC) $(HC_OPTS) $(MAGIC_FLAGS) -i -Icbits -Imk -c $< -o $@ -ohi $(basename $@).$(way_)hi

yi-inplace: yi-inplace.in
	@sed 's,@YI_TOP@,'`pwd`',g' yi-inplace.in > yi-inplace
	@chmod 755 yi-inplace

EXTRA_CLEANS+= yi-inplace

EXTRA_CLEANS+=Yi/Syntax/TestLex.hs Yi/Syntax/TestParse.hs

#
# Let's run the testsuite
#
.PHONY: check
check: 
	@echo "====== Running unit tests ========="
	@( cd testsuite && $(MAKE) run-utests && ./run-utests )

# Dependency orders

ifndef FAST
-include $(TOPDIR)/depend 
endif


