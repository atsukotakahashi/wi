-- 
-- Copyright (C) 2004 Don Stewart - http://www.cse.unsw.edu.au/~dons
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation; either version 2 of
-- the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
-- 02111-1307, USA.
-- 

--
-- Front end to the library, for use by external scripts. Just reexports
-- a bunch of modules.
--
-- You should therefore: 
--      import HEmacs.HEmacs
-- in your ~/.hemacs/Config.hs
--

module HEmacs.HEmacs (
        
        module HEmacs.Editor,
        module HEmacs.Config,
        module HEmacs.Core,
        module HEmacs.Version,
 
   ) where

import HEmacs.Editor
import HEmacs.Config
import HEmacs.Core
import HEmacs.Version

-- and anything else that might be useful to write code to

