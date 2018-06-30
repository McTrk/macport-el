;;; macport.el --- Manage Mac Ports in Emacs

;; Copyright (C) 2007, 2008, 2009 Tom Tromey <tromey@redhat.com>
;; Copyright (C) 2011-2018 Mustafa Kocaturk <m.kocaturk@computer.org>

;; Author: Mustafa Kocaturk <m.kocaturk@computer.org>
;; Created: 24 Jun 2011
;; Version: 1.1
;; Keywords: tools

;; This file is not part of GNU Emacs.
;; However, it is distributed under the same license.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Change Log:

;; 24 Jun 2011 Initial version
;; (based on package.el version 0.9 by Tom Tromey)

;;; Commentary:

;; This is an Emacs interface for maintaining software
;; packages available for, or installed on, a MacOS X system in
;; accordance with the Mac ports system (http://www.macports.org).
;; Ports and groups are listed in a special outline buffer, where
;; each can be marked for upgrade, installation, or deletion.
;; Full details of each port can be searched and exposed,
;; dependencies can be traced through hyperlinks, and contents listed.
;;
;; Interaction with the system occurs through the `port' command
;; in a dedicated process buffer, in which the user can
;; view progress and issue additional commands when needed.
;;
;; To use this, put macport.el somewhere on your load-path.
;; Then add this to your .emacs.d/init.el:
;;
;;    (load "macport")
;;    (macport-initialize)
;;
;;
;; M-x macport-list
;;    Enters a mode similar to buffer-menu which lets you manage
;;    ports.  You can choose Mac ports for install (mark with "i", then
;;    "x" to execute) or deletion, and you can see what ports are
;;    available.  This will automatically fetch the latest list of
;;    ports.
;;
;; M-x macport-list-no-fetch
;;    Like macport-list, but does not automatically fetch the
;;    new list of ports.
;;
;; The idea behind macport.el is to be able to browse, select,
;; install, update, or uninstall a port through a user-friendly menu
;; system.  A port is described by its name and version, has
;; versioned dependencies, and steps to build it, defined in a Portfile.
;; When installing or upgrading a port, the `port' command will read
;; the Portfile, download, upgrade, or build all prerequisite ports,
;; as needed.

;; The menu supports the following port operations:
;; Mark Operation    Description
;; ==== =========    ===========
;; I    Download.    Fetch the port sources.
;; I    Install.     Extract, build, and install the port.
;; I    Activate.    Make the port available to the user.
;; I    Update.      Download, install, and activate a newer version of an installed port.
;; *    Deactivate.  Take a port out of service (e.g., at update).
;; D    Uninstall.   Uninstall a port (e.g., when outdated, inactive, or no longer needed).
;; *    Clean.       Remove downloaded files and temporary files, e.g., after a failed build.
;; where asterisk (*) means manually entering a command into the process buffer.
;; 

;;; Thanks:
;;  Tom Tromey <tromey@redhat.com>

;;; ToDo:

;; - complete the task of subgrouping ports by prefix, such as "py-" or "p5-" in the outline menu

;;; Code:

(defconst macport-el-version "$Id: macport.el,v 1.136 2018/06/30 17:33:05 mu Exp mu $" "Version of macport.el.")

(require 'outline)
(require 'comint)

(defgroup macport nil "Install and maintain Mac ports." :group 'external)
(defcustom macport-user-ports-dir (expand-file-name (convert-standard-filename "~/.macports/ports/")) "User's Mac ports source directory." :group 'macport)
(defcustom macport-prefix "/opt/local/" "Top-level directory under which Mac port system is installed." :group 'macport)
(defun macport-addpath (f) "Add macport path prefix to relative file name"
       (let ((d (file-name-directory f)) (n (file-name-nondirectory f))) (concat macport-prefix (or d "bin/") n)))
(defcustom macport-port-command (macport-addpath "port") "Mac `port' command." :group 'macport)
(defcustom macport-home-dir (concat macport-prefix "var/macports/") "Local directory where Mac Port installation resides." :group 'macport)
;; .schema
;; CREATE TABLE dependencies (id INTEGER, name TEXT, variants TEXT, FOREIGN KEY(id) REFERENCES ports(id));
;; CREATE TABLE files (id INTEGER, path TEXT, actual_path TEXT, active INT, mtime DATETIME, md5sum TEXT, editable INT, binary BOOL, FOREIGN KEY(id) REFERENCES ports(id));
;; CREATE TABLE metadata (key UNIQUE, value);
;; CREATE TABLE ports (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT COLLATE NOCASE, portfile CLOB, url TEXT, location TEXT, epoch INTEGER, version TEXT COLLATE VERSION, revision INTEGER, variants TEXT, negated_variants TEXT, state TEXT, date DATETIME, installtype TEXT, archs TEXT, requested INT, os_platform TEXT, os_major INTEGER, UNIQUE (name, epoch, version, revision, variants), UNIQUE (url, epoch, version, revision, variants));
;; CREATE INDEX dep_name ON dependencies (name);
;; CREATE INDEX file_actual ON files(actual_path);
;; CREATE INDEX file_binary ON files(binary);
;; CREATE INDEX file_path ON files(path);
;; CREATE INDEX file_port ON files (id);
;; CREATE INDEX port_name ON ports (name, epoch, version, revision, variants);
;; CREATE INDEX port_state ON ports (state);
;; CREATE INDEX port_url ON ports (url, epoch, version, revision, variants);

(defcustom macport-db-file (cons (concat macport-home-dir "registry/registry.db") '(0 . 0)) "Path and modtime of the database file of locally installed Mac ports." :group 'macport)
(defcustom macport-ports-dir (concat macport-home-dir "sources/rsync.macports.org/release/tarballs/ports/") "Mac ports source directory." :group 'macport)
(defconst macport-portindex "PortIndex" "Mac port index file name.")
(defcustom macport-index-file (cons (concat macport-ports-dir macport-portindex) '(0 . 0)) "Mac port system index file and its modtime." :group 'macport)
(defcustom macport-user-index-file (cons (concat macport-user-ports-dir macport-portindex) '(0 . 0)) "Mac port user index file and its modtime." :group 'macport)

(defcustom macport-epoch-matters nil "Include epoch in version comparison." :type 'boolean :group 'macport)

(defvar macport-ports (make-vector 509 nil) "Dictionary of Mac port names.")
(defvar macport-prefixes (make-vector 13 nil) "Dictionary of Mac port name prefixes.")
(defvar macport-attributes (make-vector 13 nil) "Dictionary of field names encountered in a PortFile entry.")
(defconst macport-space-key "space" "Name of space property")
(defconst macport-dependents-key "dependents" "Name of dependents property")
(defconst macport-state-key ":state" "Attribute name for state plist of Mac port")
(defconst macport-imaged-key "imaged" "Name for imaged state attribute of Mac port")
(defconst macport-installed-key "installed" "Name for installed state attribute of Mac port")
(defconst macport-state-attributes
  (list macport-space-key (list "space" "\\(.*\\) %s" "\\1")
	macport-dependents-key (list "dependents" "\\(?:\\(?1:[^ ]+\\) depends on %s\\|[^ ]+ +has \\(?1:\\)no dependents\\.\\)" "\\1" "port")
	macport-installed-key nil
	macport-imaged-key nil) "PList of state field and method to update, port command, value regexp, and substitution string.")
(defvar macport-categories (make-vector 47 nil) "Mac port categories.")
(defconst macport-builtins (list "MacPorts" "MacPorts_Framework") "Ports not to be deleted")

(defcustom macport-outdated-face font-lock-warning-face "Face for outdated Mac port" :group 'macport)
(defcustom macport-installed-face font-lock-negation-char-face "Face for installed Mac port" :group 'macport)
(defcustom macport-notinstalled-face font-lock-function-name-face "Face for not installed Mac port" :group 'macport)
(defcustom macport-group1-face font-lock-constant-face "Face for Mac port level 1 group header" :group 'macport)
(defcustom macport-inactive-face font-lock-keyword-face "Face for inactive (imaged) Mac port" :group 'macport)
(defcustom macport-builtin-face font-lock-builtin-face "Face for built-in Mac port" :group 'macport)

(defvar macport-pseudo-ports
  (list
   (list "Outdated" "outdated"  macport-outdated-face)
   (list "Inactive" "inactive"  macport-inactive-face)
   (list "Installed" "installed"  macport-installed-face)
   (list "Not-Installed" "( not installed )"  macport-notinstalled-face)
   ) "Pseudo Mac port titles, names, and faces")

(defconst macport-heading-categorized "Categorized" "Heading for Categorized section of Mac ports menu buffer")

(defun macport-builtin-p (p) "Return t if name of symbol P is a member of `macport-builtins'." (member p macport-builtins))

(defvar macport-history nil "Stack of ports user has visited with `macport-goto-node' command.")
(defvar macport-history-forward nil "Stack of ports user has visited with `macport-last' command.")

(defvar macport-su-process-name (file-name-nondirectory macport-port-command) "Name of superuser process running the Mac port command.")
(defvar macport-su-process nil "Process buffer running Mac `port' command with sudo.")
(defcustom macport-port-prompt-regexp "^\\[[^][]+\\] > " "Regexp to match prompt expected from the interactive `port' command." :group 'macport)
(defvar macport-command-sent nil "Non-nil indicates port process is handling a copmmand.")
(defvar macport-first-prompt nil "Non-nil when the first prompt is expected from a starting port process.")

(defun macport-time-stamp ()
  "Return string with local date, time, and time zone."
  (format-time-string "[%F %T %Z] "))

(defface macport-time-stamp-face
  '((((class color) (background light))
     (:foreground "yellow green" :background "ghost white"))
    (((class color) (background dark)) (:foreground "gray85")))
  "Face for time stamp in Mac port comint buffer" :group 'macport)

(defun macport-time-stamp-visible (&optional on)
  "Turn time stamp visibility ON or toggle if nil."
  (interactive "P")
  (let ((i (member 'macport-time-stamp buffer-invisibility-spec)))
    (if (or i on)
	(remove-from-invisibility-spec 'macport-time-stamp)
      (add-to-invisibility-spec 'macport-time-stamp))))

(defun macport-time-stamp-propertize (&rest ts)
  "Propertize TS or time stamp and fontify."
  (propertize
   (if ts (apply #'concat ts) (macport-time-stamp))
;;   'invisible 'macport-time-stamp
   'face 'macport-time-stamp-face))

(defun macport-watch-for-prompt (s)
  "Revert port menu buffer when prompt is seen in S.
This function could be in the list `comint-preoutput-filter-functions'."
  (or
   (and
    macport-command-sent
    (string-match macport-port-prompt-regexp s)
    (let* ((ts (macport-time-stamp-propertize))
	   (r (replace-match (concat ts "\n\\&") t nil s)))
      (if macport-first-prompt (setq macport-first-prompt nil)
	(message "%s completed at %s." macport-command-sent ts)
	(macport-menu-revert) (setq macport-command-sent nil))
      r)) s))

(defun macport-insert-comint-timestamp (&optional s)
  "Insert timestamp when input S is about to be sent to process."
  (let ((mv (comint-after-pmark-p)))
    (save-excursion
      (comint-goto-process-mark)
      (insert (macport-time-stamp-propertize))
      ;; (comint-skip-input)
      (comint-set-process-mark))
    (if mv (comint-goto-process-mark))))

(defun macport-do (confirm cmd &rest args)
  "CONFIRM sending CMD and ARGS to Mac `port' process."
  (let* ((pc (concat cmd " " (mapconcat 'identity args " ")))
	 (ms (format "process %s command \"%s\"" macport-su-process-name pc)))
    (if (or confirm (yes-or-no-p (format "Send %s? " ms)))
	(let* ((ts (macport-time-stamp))
	       (m (message "Sending %s at %s..." ms ts)))
	  (comint-send-string
	   (prog1
	       (if (comint-check-proc macport-su-process) macport-su-process
		 (with-current-buffer
		     (setq macport-su-process
			   (with-current-buffer (dired "/sudo:localhost:~/")
			     ;; (setq default-directory "/sudo:localhost:~/")
			     (prog1 (make-comint macport-su-process-name macport-port-command) (kill-buffer))))
		   (setq comint-prompt-regexp macport-port-prompt-regexp
			 macport-first-prompt t)
		   (remove-from-invisibility-spec 'macport-time-stamp)
		   (add-hook (make-local-variable 'comint-preoutput-filter-functions) 'macport-watch-for-prompt)
;;		   (add-hook (make-local-variable 'comint-input-filter-functions) 'macport-insert-comint-timestamp)
		   )
		 macport-su-process)
	     (with-current-buffer macport-su-process (macport-insert-comint-timestamp))
	     (display-buffer macport-su-process)) (concat pc "\n"))
	  (message "%s done" m) (setq macport-command-sent ms)))))

(defun macport-sql-do (cmd)
  "Send CMD to sqlite3 on Mac ports registry database.
Return lines of output as a list."
  (process-lines "sqlite3" (car macport-db-file) cmd))

(defun macport-put (p a v) "Put in Mac port P's attribute A value V." (put p (intern a macport-attributes) v))
(defun macport-get (p a) "Get value of Mac port P's attribute A." (get (intern-soft (if (symbolp p) (symbol-name p) p) macport-ports) (intern-soft a macport-attributes)))
(defun macport-nullp (v) "True if V is nil, empty string, or zero."
  (or (null v) (= (string-to-number v) 0)))

(defun macport-vre (v r e &optional vnt) "Make string combining version V, revision R, epoch E, and variant VNT."
  (concat
   v (if (macport-nullp r) "" (concat "_" r))
   (if (macport-nullp e) "" (concat ";" e))
   (or vnt "")))

(defun macport-vers (p) "Get version of Mac port P."
  (macport-vre
   (macport-get p ":version")
   (macport-get p ":revision")
   (if macport-epoch-matters
     (macport-get p ":epoch"))))

(defun macport-categories-add (port-id cl)
  "Add PORT-ID to port categories listed in CL."
  (mapc
   (lambda (c)
     (let ((s (or (intern-soft c macport-categories)
		  (let ((i (intern c macport-categories))) (set i nil) i))))
       (add-to-list s port-id))) cl))

(defun macport-read-portindex (&optional p a)
  "Read from next entry matching P attributes matching A in current buffer."
  (let ((pr (concat "^\\(" (or p "\\S-+") "\\)\\s-+\\([0-9]+\\)\\s-*$"))
	(ar (concat "\\s-*\\(" (or a "[a-zA-Z][a-zA-Z_0-9]*") "\\)\\s-+\\(?:\\({.*?\\)\\|\\([^{]\\S-*\\)\\)")))
    (while (re-search-forward pr nil t)
      (let* ((pin (match-string 1))
	     (el (string-to-number (match-string 2)))
	     (ee (+ el (point))))
	(and
	 pin
	 (let ((pi (intern pin macport-ports)))
	   (if (string-match "\\`\\([^ -]+\\)-" pin)
	       (let ((pp (intern (match-string 1 pin) macport-prefixes)))
		 (macport-put pi ":name-prefix" pp)
		 (push pi pp)))
	   (while (re-search-forward ar ee t)
	     (let* ((fn (match-string 1))
		    (fv (or (match-string 3)
			    (let* ((lb (match-beginning 2))
				   (le (scan-lists lb 1 0)))
			      (goto-char le)
			      (buffer-substring (1+ lb) (1- le))))))
	       (and fn fv
		    (progn
		      (if (string= fn "categories")
			  (macport-categories-add
			   pi (setq fv (split-string fv))))
		      ;; --category
		      ;; --depends
		      ;; --fullname
		      ;; --heading
		      ;; --index
		      ;; --line
		      ;; --maintainer
		      ;; --platform
		      ;; --pretty
		      ;; --variant
		      ;;
		      ;; (
		      ;; "subports"
		      ;; "installs_libs"
		      ;; "depends_run"
		      ;; "replaced_by"
		      ;; "depends_build"
		      ;; "depends_fetch"
		      ;; "depends_lib"
		      ;; "revision"
		      ;; "categories"
		      ;; "version"
		      ;; "depends_extract"
		      ;; "maintainers"
		      ;; "license"
		      ;; "long_description"
		      ;; "name"
		      ;; "platforms"
		      ;; "epoch"
		      ;; "homepage"
		      ;; "description"
		      ;; "portdir"
		      ;; "variants"
		      ;; )

		      (macport-put pi (concat ":" fn) fv)))))))))))

(defvar macport-state nil "Installed or imaged Mac ports")

(defun macport-append (pn an v) "Append to port PN's state attribute AN value V"
  (let* ((p (intern pn macport-ports))
	 (pl (macport-get p macport-state-key))
	 (al (lax-plist-get pl an)))
    (macport-put
     p macport-state-key
     (lax-plist-put
      pl an
      (cond
       ((null al) (list v))
       ((listp al) (add-to-list 'al v))
       (t (list v al)))))
    (add-to-list 'macport-state p)))

(defun macport-read-port-line (s)
  "Read in port name, version, and state from string S."
  (if (string-match
	 ;; Command line "port list installed" is too slow;
	 ;; therefore using sql instead directly on db
	 ;; match output of
	 ;; "select name,epoch,version,revision,state,variants from ports;"
	 "^\\s-*\\([^|]+\\)|\\([^|]+\\)|\\([^|]+\\)|\\([^|]+\\)|\\([^|]+\\)|\\([^| 	]*\\)\\s-*$" s)
    (let ((pn (match-string 1 s))
	  (pe (match-string 2 s))
	  (pv (match-string 3 s))
	  (pr (match-string 4 s))
	  (ps (match-string 5 s))
	  (pt (match-string 6 s)))
      (and pn ps pv
	(macport-append pn ps (macport-vre pv pr pe pt))
	(macport-append pn macport-space-key nil)
	(macport-append pn macport-dependents-key nil)
	))))

(defun macport-file-modified-p (f) "Return t if file in F has been updated.
F contains (file name . modtime)."
  (let ((imt (nth 5 (file-attributes (car f))))) (prog1 (time-less-p (cdr f) imt) (setcdr f imt))))

(defun macport-installed-ports (&optional force)
  "Read installed version of Mac ports if db has changed or if FORCE is non-nil."
  (and (or force (macport-file-modified-p macport-db-file))
       (progn (mapc (lambda (p) (macport-put p macport-state-key nil)) macport-state)
	      (mapc 'macport-read-port-line
		    (macport-sql-do "select name,epoch,version,revision,state,variants from ports;")))))

(defun macport-read-index (index &optional force)
  "Read Mac ports INDEX file if it has changed or if FORCE is non-nil.
Fill results into array `macport-ports'.
INDEX is a cons of the file name and modtime."
  (if (or force (macport-file-modified-p index))
      (with-temp-buffer
	(insert-file-contents-literally (car index))
	(mapc
	 (lambda (c) (modify-syntax-entry c "."))
	 '(?\( ?\) ?\[ ?\] ?\' ?\` ?\" ?\| ?\\))
	(mapc
	 (lambda (c) (modify-syntax-entry c " "))
	 '(?\n ?\r))
	 ;; TODO: move other specials to these lists as they break scanning
	(goto-char (point-min))
	(macport-read-portindex nil nil))))

(defun macport-initialize (&optional force)
  "Load all Mac ports if a file has changed or if FORCE is non-nil."
  (macport-read-index macport-index-file force)
  (macport-read-index macport-user-index-file force)
  (macport-installed-ports force))

(defun macport-act (confirm cmd names &rest tail)
  "CONFIRM action CMD on the Mac ports listed in NAMES, appending TAIL.
The port is found in the PortIndex file fetched from the archive site."
  (let ((l (delq nil names)))
    (if l (apply 'macport-do confirm cmd (if tail (nconc l tail) l)))))

(defun macport-refresh ()
  "Download the Mac ports archive description.
Ensure that the latest versions of all ports are known."
  (interactive)
  (macport-do t "selfupdate"))



;;;; Mac Ports menu mode.

(defvar macport-menu-mode-map nil
  "Local keymap for `macport-menu-mode' buffers.")

(defun macport-menu-widen () "Hide or show port process window."
       (interactive)
       (if (get-buffer-window macport-su-process)
	   (delete-windows-on macport-su-process)
	 (display-buffer macport-su-process)))

(or macport-menu-mode-map
  (setq macport-menu-mode-map 
	(let ((m (make-keymap)))
	  (suppress-keymap m)
	  (mapc
	   (lambda (b) (let ((c (car b))) (mapc (lambda (k) (define-key m k c)) (cdr b))))
	   '((quit-window "q")
	     (next-line "n")
	     (previous-line "p")
	     (isearch-forward "/")
	     (isearch-backward "\\")
	     (scroll-up " ")
	     (scroll-down [backspace])
	     (macport-menu-widen "w")
	     (outline-up-heading "[")
	     ;;  (outline-next-visible-heading [tab])
	     ;;  (outline-previous-visible-heading [(shift tab)])
	     (macport-menu-mark-unmark "u")
	     (macport-menu-backup-unmark "y")
	     (macport-menu-mark-delete "d" "-")
	     (macport-menu-mark-install "i" "+")
	     (macport-menu-files "f")
	     (macport-menu-portfile "v")
	     (macport-menu-revert "g")
	     (macport-menu-refresh "G" "R")
	     (macport-menu-execute "x")
	     (macport-menu-quick-help "h")
	     (macport-forward-hyperlink [tab])
	     (macport-backward-hyperlink [(shift tab)])
	     (macport-hide-subtree [left])
	     (macport-show-subtree [right] "?")
	     (macport-flag-subtree [return])
	     (macport-last "l")
	     (macport-history-forward "r" "L")))
	  m)))

(defvar macport-menu-sort-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-2] 'macport-menu-sort-by-column)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Local keymap for Mac ports menu sort buttons.")

(defconst macport-mouse-help "mouse-1: sort by column")

(defun macport-file-ts (f &optional l)
  "Form time stamp string with file name F and optional prefix L."
  (format
   "\n%30s" (concat (or l "") (and l " ") (file-name-nondirectory (car f)) ": "  (format-time-string "%D %T %Z" (cdr f)))))

(defun macport-version-ts (w o p)
  (let ((s "System") (u "User"))
    (concat
     macport-mouse-help "\nLast update:"
     (macport-file-ts macport-user-index-file u)
     (macport-file-ts macport-index-file s)
     (macport-file-ts macport-db-file s))))

(defun macport-bh (w o p) "Balloon help for window W, object O, point P."
       (let ((b (previous-single-property-change p 'help-echo))
	     (e (next-single-property-change p 'help-echo)))
	 (and b e (buffer-substring b e))))

(defun dashtail (p r v) "Replace dash-terminated prefix in P with R in V."
       (let ((a (if (stringp p)
		    (replace-regexp-in-string
		     (replace-regexp-in-string "\`\\([^-]+-\\).*\'" "\\`\\1" p) (or r "") v t t) v))) (message "p: %s, r: %s, v: %s, a: %s" p r v a) a))

(defvar macport-alt-bgcolor (apply 'color-rgb-to-hex (mapcar (lambda (v) (+ v (if (< 0.5 v) -0.125 0.125 ))) (color-name-to-rgb (face-attribute 'default :background)))))

(defconst macport-columns
  '(("****" 1 (lambda (e) (let ((l (nth 3 e))) (case l (0 "*   ") (1 " *  ") (2 "  * ") (3 "   *") (t "    ")))) macport-mouse-help)
    ("Mac port" 6 (lambda (e) (symbol-name (nth 0 e))) macport-mouse-help)
    ("Version/ct" 26 (lambda (e) (or (nth 1 e) "")) macport-version-ts)
    ("Description" 39 (lambda (e) (let ((d (or (nth 2 e) "-"))) (propertize d 'help-echo 'macport-bh 'mouse-face 'highlight))) macport-mouse-help))
  "Column header properties: Text, column indent, selector, and mouse help.")

(defun macport-menu-get-port (&optional what)
  "Return the name of the port on the current line. Mark with WHAT, if non-nil."
  (outline-back-to-heading t)
  (let* ((c (car (cdr (car (cdr macport-columns)))))
	 (pc (+ (point) c))
	 (d (get-text-property pc :data)))
    (if d
	(prog2
	    (forward-char c)
	    (list
	     d
	     (let ((n (if (looking-at "[ \t]*\\([^* \t]*\\)") (match-string-no-properties 1))))
	       (case (car d)
		 (1 (concat "category:" n))
		 (2 (concat
		     "( "
		     (nth 1 (save-excursion
			      (outline-up-heading 1)
			      (macport-menu-get-port))) " and "
			      (nth 1 (assoc-string n macport-pseudo-ports)) " )"))
		 (t n))))
	  (if what
	      (let ((buffer-read-only nil) (tp (text-properties-at pc)))
		(beginning-of-line)
		(delete-char 1)
		(insert (apply 'propertize what tp))
		(outline-back-to-heading t)
		(outline-get-next-sibling))))
      (if (bobp) nil
	(outline-up-heading 1)
	(macport-menu-get-port what)))))

(put 'macport-menu-mode 'mode-class 'special)

(defun macport-menu-mode ()
  "Major mode for browsing a list of Mac ports.
Letters do not insert themselves; instead, they are commands.
\\<macport-menu-mode-map>
\\{macport-menu-mode-map}"
  (kill-all-local-variables)
  (use-local-map macport-menu-mode-map)
  (setq major-mode 'macport-menu-mode)
  (setq mode-name "Mac Port Menu")
  (setq truncate-lines t)
  (add-to-invisibility-spec '(outline . t)) ; 
  (set (make-local-variable 'outline-regexp) ". *[^ ]")
  ;; (set (make-local-variable 'outline-regexp) ". *\\(:?[^ ]*-\\)[^ ]")
  (setq selective-display-ellipses t)
  (setq buffer-read-only t)
  ;; Support Emacs 21.
  (if (fboundp 'run-mode-hooks)
      (run-mode-hooks 'macport-menu-mode-hook)
    (run-hooks 'macport-menu-mode-hook)))

(defun macport-menu-refresh ()
  "Download the Mac ports archive.
This fetches the file describing the current contents of
the Mac port archive, and then refreshes the
Mac ports menu.  This lets you see what new Mac ports are
available for download."
  (interactive)
  (macport-refresh)
  (macport-list-internal))

(defun macport-menu-revert (&optional force)
  "Update the list of Mac ports, rereading files if FORCE is non-nil."
  (interactive "P")
  (macport-initialize force)
  (macport-list-internal))

(defun macport-menu-mark-internal (what)
  "Put mark WHAT on current line and advance to next line."
  (macport-menu-get-port what))

(defun macport-next-hyperlink (b &optional a)
  "Go to the next hyperlink in buffer, searching towards buffer position B.
Starting point of the search is buffer position A, or point if A is nil.
Wrap around if not found."
  (let (l cmp cpc wp (pr 'follow-link ;; 'goto-address
			 ))
    (setq a (or a (point)))
    (if (< a b)
        (setq cmp '< cpc 'next-single-char-property-change wp 'point-min)
      (setq cmp '> cpc 'previous-single-char-property-change wp 'point-max))
    (or
     (and (funcall cmp a b)
          (setq l (funcall cpc a pr nil b))
          (or
           (and
            (funcall cmp l b)
            (if (get-char-property l pr)
                l
              (macport-next-hyperlink b l)))
           (macport-next-hyperlink a (funcall wp))))
     (point))))

(defun macport-forward-hyperlink ()
  "Go forwards to the next hyperlink in buffer."
  (interactive)
  (goto-char (macport-next-hyperlink (point-max))))

(defun macport-backward-hyperlink ()
  "Go backwards to the next hyperlink in buffer."
  (interactive)
  (goto-char (macport-next-hyperlink (point-min))))

;; fixme numeric argument
(defun macport-menu-mark-delete (num)
  "Mark NUM ports for deletion and move to the next line."
  (interactive "p") (macport-menu-mark-internal "D"))

(defun macport-menu-mark-install (num)
  "Mark NUM ports for installation and move to the next line."
  (interactive "p") (macport-menu-mark-internal "I"))

(defun macport-menu-mark-unmark (num)
  "Clear any mark on NUM ports and move to the next line."
  (interactive "p") (macport-menu-mark-internal " "))

(defun macport-menu-backup-unmark ()
  "Back up one line and clear any mark on that port."
  (interactive) (forward-line -1) (macport-menu-mark-internal " ") (forward-line -1))

(defun macport-menu-quick-help ()
  "Show short key binding help for `macport-menu-mode'."
  (interactive) (message "n-ext, i-nstall, d-elete, u-nmark, x-ecute, r-efresh, h-elp"))

(defconst macport-buf "*Mac Ports*" "Name of Mac port menu buffer.")
(defcustom macport-attr-face font-lock-type-face "Face for Mac port attribute name" :group 'macport)

(defun macport-member (v iv) "Find Mac port version V in list IV of installed mac port version_revision;epoch+variant entries"
  (let* ((l (length v)) r (x (- 0 1 l)) (xi x) (n l))
    (mapc (lambda (i)
	    (let ((c (compare-strings v 0 nil i 0 l t)))
	      (if c (if (eq c t)
			(setq r c)
		      (if (> 0 c)
			  (if (< c n)
			      (setq n c))
			(if (> c x)
			    (setq x c))))))) iv)
    (or r (if (< 0 x) x (if (> 0 n) n nil)))))

(defun macport-head-re (n &optional p) "Return regexp matching prefix P of header of level N."
       (concat "^." (regexp-quote (funcall (caddar macport-columns) (list nil nil nil n))) " \\<\\(?:" (or p ".+") "\\)\\>"))

(defvar macport-pseudo-head2-re
  (macport-head-re 2 (mapconcat (lambda (x) (regexp-quote (nth 0 x))) macport-pseudo-ports "\\|"))
  "Regexp matching pseudo port second level header.")

(defun macport-goto-category (cat)
  "Move to line of port category CAT."
  (goto-char macport-categorized-marker) (macport-show-subtree)
  (re-search-forward (macport-head-re 1 (regexp-quote cat))))

(defun macport-goto-port (name &optional a b)
  "Move to line of port named NAME between markers A and B or point and buffer end."
  (let (f (pb (concat (macport-head-re nil (regexp-quote name)) "\\s-")))
    (if a (goto-char a))
    (while (and (null f) (< (point) b))
      (re-search-forward macport-pseudo-head2-re b t)
      (macport-show-subtree) (forward-line)
      (setq f (re-search-forward pb b t)))
    (macport-show-subtree)))

(defun macport-goto-category-port (name)
  "Move to line of port named NAME under its primary category."
  (macport-goto-category (car (macport-get name ":categories")))
  (macport-goto-port
   name (point-marker)
   (progn
     (macport-show-subtree)
     (re-search-forward (macport-head-re 1) nil t 2)
     (point-marker))))

(defcustom macport-dired-prefix "/tmp*" "Root of file system tree for Mac port file listings." :group 'macport)

(defun macport-source-dirlist (dir)
  "List directories for relative port source directory DIR."
  (let ((l) (d))
    (mapc
     (lambda (x)
       (if (file-directory-p (setq d (concat x dir)))
	   (setq l (cons d l))))
     (list macport-user-ports-dir macport-ports-dir)) l))

(defcustom macport-dired-buffer-name-format "/Mac port %s %s"
  "Mac port source or content dired buffer name format.
Should be an absolute path under an existing parent directory.
Should contain only one directory separator as its first character
and exactly two %s format specifiers, one each for port name and directory type." :group 'macport)

(defun macport-source-dired (dir)
  "List files in DIR relative to Mac-port-source, in dired."
  (interactive)
  (let ((l (macport-source-dirlist dir)))
    (if l
	(progn
	  (dired-other-window
	   (cons (format macport-dired-buffer-name-format
			 (replace-regexp-in-string ".*/" "" dir) "source") l))
	  (mapc
	   (lambda (x)
	     (dired-goto-subdir x)
	     (dired-insert-subdir x)
	     ;; (dired-do-redisplay)
	     ) l))
      (user-error "Mac port source directory \"%s\" not found" dir))))

(defun macport-menu-files ()
  "List files of current Mac port in dired."
  (interactive)
  (let* ((pd (macport-menu-get-port)) (p (car (cdr pd))) (c "content"))
    (dired-other-window
     (cons (format macport-dired-buffer-name-format p c)
	   (cdr (mapcar (lambda (s) (replace-regexp-in-string "^ +" "" s t t))
			(process-lines "port" c p)))))))

(defun macport-menu-portfile ()
  "View Portfile of current Mac port."
  (interactive)
  (let* ((pd (macport-menu-get-port)) (p (car (cdr pd))) (c "file"))
    (view-file-other-window (car (process-lines "port" c p)))))

(defun macport-dired (f n)
  "List file F under Mac port N in dired."
  (let ((fp (macport-addpath f)))
    (if (file-exists-p fp)
	(dired-other-window (list (format macport-dired-buffer-name-format n "file") fp))
      (user-error "File \"%s\" not found" fp))))

(defun macport-goto-node (type file name)
  "Show information on link of TYPE, FILE, or port with NAME.
Argument TYPE is type of link."
  (setq macport-history (cons (point-marker) macport-history))
  (let ((l (assoc type macport-link-types)))
    (cond (l (apply (nth 1 l) (list file name)))
	  (t (user-error "Unknown link type \"%s\"" type)))))

(defun macport-last ()
  "Go back in the history to the last node visited."
  (interactive)
  (or macport-history (user-error "This is the first node you looked at"))
  (let ((hf (cons (point-marker) macport-history-forward))
	(p (car macport-history)))
	(setq macport-history (cdr macport-history)
	      macport-history-forward hf)
	(goto-char p)))

(defun macport-history-forward ()
  "Go forward in the history of visited nodes."
  (interactive)
  (or macport-history-forward (user-error "This is the last node you looked at"))
  (let ((hf (cdr macport-history-forward))
	(p (car macport-history-forward)))
	(setq macport-history (cons (point-marker) macport-history)
	      macport-history-forward hf)
	(goto-char p)))

(defun macport-follow-link (&optional posn)
  "Follow a link at position P.
Optional argument POSN contains event position."
  (interactive)
  (let* ((p (or posn (posn-at-point)))
	 (s (and p (posn-string p)))
	 (a (if s (get-text-property (cdr s) 'link-args (car s))
	       (get-char-property (posn-point p) 'link-args))))
    (apply 'macport-goto-node a) ;; see `macport-propertize'.
    ))

(defun macport-mouse-follow-link (click)
  "Follow a link where you CLICK."
  (interactive "@e") (macport-follow-link (event-start click)))

(defvar macport-link-map
  (let ((m (make-sparse-keymap)))
    (define-key m [return]      'macport-follow-link)
    (define-key m [mouse-2]     'macport-mouse-follow-link)
    (define-key m [follow-link] 'mouse-face)
    m)
  "Local keymap for Mac ports menu hyperlinks.")

(defun macport-format (ty v)
  "Apply format and type TY to propertize port or file name in V based on its status."
   (if v (concat (macport-propertize (format "%s" v) ty) " ") ""))

(defcustom macport-link-types
  (let ((lgc (lambda (f n) (macport-goto-category-port n))))
    `(("port" ,lgc ("subports" "replaced_by" "conflicts"))
      ("path" ,lgc ())
      ("file" macport-dired ())
      ("lib"  ,lgc ())
      ("bin"  ,lgc ())
      ("dir"  (lambda (f n) (macport-source-dired n)) ("portdir"))
      ("cat"  (lambda (f n) (macport-goto-category n)) ("categories"))))
  "List of triplets: Mac port link type, viewing method, and list of applicable attributes." :group 'macport)

(defvar macport-attrib-types
  (let ((l))
    (mapc (lambda (x) (let ((y (nth 0 x))) (mapc (lambda (a) (setq l (cons a (cons y l)))) (nth 2 x))))
	  macport-link-types) l)
"Plist of Mac port attribute name and type pairs.
Type is a string specifying the default type of the attribute's value.")

(defvar macport-value-regexp
  (concat "\\<\\(?:\\(?1:[^: ]+\\):\\)?\\(?2:[^: ]*\\)")
  "Regexp matching a pattern like [file:]name in attribute value.")

(defvar macport-type-value-regexp
  (concat "\\<\\(?1:" (mapconcat 'car macport-link-types "\\|")
	  "\\)?\\(?::\\(?2:[^: ]+\\)\\)?:\\(?3:[^: ]*\\)")
  "Regexp matching a pattern like [type][:file]:name in attribute value.")

(defun macport-face (p &optional f)
  "Return a face reflecting status of port P with optional default face F."
  (and p (let* ((ps (macport-get p macport-state-key))
	 (v (macport-vers p))
	 (iv (lax-plist-get ps macport-installed-key))
	 (mv (lax-plist-get ps macport-imaged-key)))
    (and
     iv
     (setq f
	   (let ((m (macport-member v iv)))
	     (cond
	      ((eq t m) macport-installed-face)
	      ((> m 0) macport-outdated-face)
	      ((< m 0) macport-notinstalled-face)))))
    (and
     mv
     (eq t (macport-member v mv))
     (setq f macport-inactive-face))
    f)))

(defun macport-link (type file last face)
  "Make link with TYPE from FILE and LAST with FACE."
  (concat
   (if file
       (let ((fp (macport-addpath file)))
	 (concat
	  (if (file-exists-p fp)
	      (propertize
	       file
	       'font-lock-face face
	       'mouse-face 'highlight
	       'follow-link t
	       'help-echo "Browse the file's directory."
	       'link-args (list "file" file last)
	       'keymap macport-link-map)
	    (propertize file 'font-lock-face macport-notinstalled-face)) ":")) "")
   (if last
       (propertize
	last
	'font-lock-face face
	;; :underline t
	'mouse-face 'highlight
	'follow-link t
	'help-echo "Follow the link."
	'link-args (list type file last)
	'keymap macport-link-map) "")))

(defun macport-propertize-word (file port type)
  "Propertize FILE and PORT based on status and TYPE."
  (macport-link
   type file port
   (cond
    ((and (member type '("port" "bin" "lib" "" nil)) port)
     (macport-face (intern-soft port macport-ports) macport-notinstalled-face))
    ((member type '("dir" "path" "cat")) macport-builtin-face)
    (t macport-notinstalled-face))))

(defun macport-propertize (sv &optional type)
  "Propertize port or file names in string SV based on status and TYPE."
  (let* ((beg 0) (s sv)
	 (re macport-type-value-regexp)
	 (pf (lambda (v)
	       (macport-propertize-word
		(match-string 2 v)
		(match-string 3 v)
		(match-string 1 v))))
	 (mb))
    (if type
	(setq
	 re macport-value-regexp
	 pf (lambda (v)
	      (macport-propertize-word
	       (match-string 1 v)
	       (match-string 2 v)
	       type))))
    (while (setq mb (string-match re s beg))
      (let* ((w (apply pf (list s)))
	     (r (replace-match w t nil s 0)))
	(setq s r beg (if r (+ mb (length w)) (match-end 0))))) s))

(defun macport-subattrib-p (f) "Return t if F is a Mac port sub-attribute symbol."
  (member f macport-state-attributes))

(defun macport-attrib-p (f) "Return t if F is a Mac port attribute symbol."
  (or (and (symbolp f) (intern-soft (symbol-name f) macport-attributes)) (macport-subattrib-p f)))

(defun macport-insert-state-attrib (pn a)
  "Insert port PN's state attribute A."
  (let ((acr (lax-plist-get macport-state-attributes a)))
    (if acr
	(let ((cmd (nth 0 acr))
	      (pnr (format (nth 1 acr) pn))
	      (pns (or (nth 2 acr) "\\1"))
	      (ty (nth 3 acr)))
	  (insert
	   (mapconcat
	    (lambda (l)
	      (macport-propertize
	       (replace-regexp-in-string pnr pns l) ty))
	    (process-lines "port" cmd pn) " "))))))

(defun macport-insert-avp (pn hp skip type &optional a v &rest r)
  "Insert under port PN, with args HP, SKIP, and TYPE, attribute A and value V.
Fontify attribute name and value.  Create links.
Repeat for the remaining attribute-value pairs in R."
  (if a
    (cond
     ((macport-attrib-p a)
      (let ((s (if (symbolp a) (symbol-name a) a)))
	(or (member s skip)
	    (let* ((m (point))
		   (n (if (string-match "^:" s)
			  (replace-match "" nil nil s) s))
		   (ty (lax-plist-get macport-attrib-types n)))
	      (insert (propertize (concat (or hp "") n ": ") 'font-lock-face macport-attr-face))
	      (cond ((equal v '(nil)) (macport-insert-state-attrib pn a))
		    ((listp v) (apply 'macport-insert-avp pn nil skip ty v))
		    ((stringp v) (insert (macport-propertize v ty)))
		    (t (insert (macport-format ty v))))
	      (if hp (progn (fill-region-as-paragraph m (point) t) (insert "\n")
			    (setq m (point))) (insert " "))))))
     (t (insert (macport-format type a) (macport-format type v)))))
    (if r (apply 'macport-insert-avp pn hp skip type r)))

(defun macport-insert-attrib (p hp skip &optional a &rest al)
  "Insert under port P, with header prefix HP and list to SKIP, attribute A.
Repeat for remaining attributes AL."
  (if a (progn (macport-insert-avp p hp skip nil (make-symbol a) (macport-get p a))
	(setq skip (apply 'macport-insert-attrib p hp (cons a skip) al)))) skip)

(defun macport-insert-fill-doc (ps) "Return full documentation for Mac port symbol PS."
  (let* ((hp (make-string (+ (car (cdr (car (cdr macport-columns)))) 2) ? ))
	 (fill-prefix (concat hp "    "))
	 (ldf ":long_description")
	 (p (symbol-name ps))
	 (ldv (macport-get p ldf))
	 (df ":description")
	 (dv (macport-get p df)))
    (and ldv
	 (let* ((r (concat "\\W*\\(" (regexp-quote dv) "\\)\\W*"))
		(s (propertize
		    (concat (substring dv 0 1) "…" (substring dv -1))
		    'help-echo dv
		    'mouse-face 'highlight))
		(i 0)
		(l (length s)))
	   (while (setq i (string-match r ldv i))
	     (setq ldv (replace-match s nil nil ldv 1)
		   i (+ i l)))
	   ldv)
	 (> (length ldv) 0)
	 (fill-region-as-paragraph (prog1 (+ (point) 4) (insert hp ldv)) (point) t)
	 (insert "\n"))
    (let ((skip (list ":name" df ldf)))
      (fill-region-as-paragraph
       (prog1 (+ (point) 4)
	 (insert hp)
	 (setq skip (macport-insert-attrib p nil skip ":revision" ":version" ":epoch"))) (point) t) (insert "\n")
	 (apply 'macport-insert-avp p hp skip nil (symbol-plist ps)))
    ;; consider: more info on other versions, port groups, etc.
    (goto-address)))

(defun macport-tree-folded-p () "Return t if macport heading has folded subtree."
  (save-excursion
    (outline-back-to-heading)
    (or (>= (funcall outline-level) (progn (outline-next-heading) (funcall outline-level))) (outline-invisible-p))))

(defun macport-flag-subtree (&optional force flag)
  "Toggle display of detail about this port.
With non-nil FORCE, show detail if FLAG is non-nil, hide otherwise."
  (interactive)
  (let* ((dp (macport-menu-get-port)))
    (if dp
      (let*
	  ((d (nth 0 dp))
	   (p (nth 1 dp))
	   (fl (get-text-property (point) 'font-lock-face))
	   (f (if (listp fl) (nth 0 fl) fl)))
	(outline-back-to-heading t)
	(save-excursion
	  (let ((op (point)))
	    (if (>= (funcall outline-level) (progn (outline-next-heading) (funcall outline-level)))
		(let ((buffer-read-only nil)
		      (g (nth 0 d))
		      (l (nth 1 d)))
		  (outline-previous-heading) (outline-end-of-heading)
		  (forward-line)
		  (narrow-to-region (point) (point))
		  (case g
		    ((1 3) (macport-list-internal l))
		    ((0 2) (macport-sort-print l f))
		    (t (macport-insert-fill-doc
			(intern-soft p macport-ports))))
		  (widen)
		  (goto-char op)
		  (outline-flag-subtree t)))))))
    (if force (outline-flag-subtree flag)
      (outline-flag-subtree (not (macport-tree-folded-p))))))

(defun macport-show-subtree () "Show subtree under Mac port header line"
  (interactive) (macport-flag-subtree t nil) (recenter-top-bottom (/ (window-height) 4)))

(defun macport-hide-subtree () "Hide subtree under Mac port header line"
  (interactive) (if (macport-tree-folded-p) (outline-up-heading 1 t)) (macport-flag-subtree t t))

(defun macport-menu-execute ()
  "Perform all the marked actions.
Download and install or upgrade ports marked for such action.
Remove ports marked for deletion."
  (interactive)
  (let (il ul dl cl dls)
    (save-excursion
      (goto-char (point-min))
      ;;  (forward-line 1)
      (while (not (eobp))
	(let ((cmd (char-after)))
	  (case cmd
	    ((?D ?I)
	     (let ((dp (macport-menu-get-port)))
	       (and dp
		    (let ((p (nth 1 dp)))
		      (if p
			  (let ((ps (intern-soft p macport-ports)))
			    (if ps
				(let ((st (macport-get ps macport-state-key)))
				  (if st
				      (case cmd
					(?D
					 (cond
					  ((macport-builtin-p p) (user-error "Can't delete built-in Mac port `%s'" p))
					  ((lax-plist-get st macport-imaged-key) (push p cl))
					  ((lax-plist-get st macport-installed-key) (push p dl))))
					(?I (push p ul)))
				    (case cmd (?I (push p il)))))
			      (setq p (nth 1 (assoc-string p macport-pseudo-ports)))
			      (case cmd
				(?I (push p ul))
				(?D (push p dls))))))))))))
	(forward-line)))
    (macport-act nil "uninstall" dl)
    (if dls (apply 'macport-do nil "uninstall" dls))
    (macport-act t "upgrade" ul)
    (macport-act t "install" il)
    (macport-act nil "uninstall inactive and (" cl ")")))

(defun macport-print-port (p &optional f h)
  "Insert line describing Mac port P with face F and prefix of H.
Line includes name, version, installed version, and description."
  (let* ((g (nth 3 p))
	 (d (nth 4 p))
	 (bp (point))
	 (ep (progn
	       ;; (and p h (setcdr (cddr p) (list g d h)))
	       (mapc
		(lambda (c) (indent-to (car (cdr c)) 1)
		  (insert (or (funcall (car (cdr (cdr c))) p) "-")))
		macport-columns) (point))))
    (add-text-properties
     bp ep
     (list
      'font-lock-face
      (list
       (if (macport-builtin-p (symbol-name (nth 0 p))) macport-builtin-face f)
       (if (= 0 (% (line-number-at-pos bp) 2)) (list :background macport-alt-bgcolor) 'default))
      :data (list g d))) (insert "\n")))

(defvar macport-menu-sort-key (cons (car (cdr (cdr (car (cdr macport-columns))))) 'string-lessp) "This decides how we should sort.")
(defvar macport-categorized-marker nil "Categorized section head position")

(defun macport-header (p n a g) "Make group header with port list P, name N, available count A, and level G."
  (let ((v (format "% 6d" a)))
    (list (make-symbol n) v (case g ((0 2) (concat n " Mac Ports")) (1 (concat "Mac Port Category " n)) (3 (concat "Mac Port Prefix " n))) g p)))

(defun macport-print-group (p n a g f) "Print group with port list P, name N, available count A, and level G, with face F."
  (and p (if (numberp a) (> a 0) a) (macport-print-port (macport-header p n a g) f nil)))

(defun macport-sort-print (ports f) "Insert sorted list of PORTS at point with face F."
  (let* ((s (car macport-menu-sort-key)) ; selector
	 (c (cdr macport-menu-sort-key)) ; comparator
	 (sf (lambda (l r) (funcall c (funcall s l) (funcall s r))))
	 (bt (get-internal-run-time))
	 (m (message "Updating buffer %s ..." (buffer-name))))
    (mapc (lambda (p) (macport-print-port p f)) (sort ports sf))
    (message "%s done (in %f seconds)" m
	     (float-time (time-subtract (get-internal-run-time) bt)))))

(defmacro macport-addinfo (r info c)
  "Add port info list R to list INFO and increment count C."
  (list 'setq info (list 'cons r info) c (list '1+ c)))

(defmacro macport-ver-if (vl bt &optional bf)
  "Perform BT if port version list VL contains string V, otherwise perform BF."
  (list 'if vl
	(list 'let (list (list 'm (list 'macport-member 'v vl)))
	      (list 'if 'm bt)) bf))

(defun macport-prep-lists (&optional cat)
  "Make four lists of Mac ports, under list CAT if non-nil.
Return list, size in the same order as in `macport-pseudo-ports'."
  (macport-initialize)
  (let*
      ((info-o) (co 0)  ;; outdated
       (info-m) (cm 0)  ;; imaged (inactive)
       (info-i) (ci 0)  ;; installed
       (info-n) (cn 0)  ;; not installed
       (make-row
	(lambda (e)
	  (if e
	    (let* ((v (macport-vers e))
		   (ps (macport-get e macport-state-key))
		   (iv (lax-plist-get ps macport-installed-key))
		   (mv (lax-plist-get ps macport-imaged-key))
		   (r (list e v (macport-get e ":description"))))
	      (macport-ver-if
	       mv (macport-addinfo r info-m cm)
	       (macport-ver-if
		iv (if (or (eq t m) (> 0 m)) (macport-addinfo r info-i ci)
		     (macport-addinfo r info-o co))
		(macport-addinfo r info-n cn))))))))
    (if cat (mapc make-row cat)
      (mapatoms make-row macport-ports))
    (list info-o co info-m cm info-i ci info-n cn)))

(defun macport-print-level (g pl) "Print Mac port groups in PL at group level G."
  (mapc (lambda (p) (macport-print-group (pop pl) (nth 0 p) (pop pl) g (nth 2 p))) macport-pseudo-ports))

(defun macport-list-internal (&optional cat) "List Mac ports in buffer under CAT if non-nil, else all."
  (let* ((pl (macport-prep-lists cat)) (n (+ (nth 5 pl) (nth 7 pl))))
    (with-current-buffer (get-buffer-create macport-buf)
      (let ((buffer-read-only nil))
	(buffer-disable-undo)
	(if cat (macport-print-level 2 pl)
	  (erase-buffer)
	  (setq macport-history nil macport-history-forward nil)
	  (macport-print-level 0 pl)
	  (setq macport-categorized-marker (point-marker))
	  (macport-print-group
	   (mapcar
	    (lambda (x)
	      (let ((vx (symbol-value x)))
		(macport-header vx (symbol-name x) (length vx) 1)))
	    (sort
	     (let (lc)
	       (mapatoms (lambda (c) (and c (push c lc))) macport-categories) lc)
	     'string-lessp))
	   macport-heading-categorized n 0 macport-group1-face)
	  (goto-char (point-min)))
	(current-buffer)))))

(defun macport-menu-sort-by-column (&optional e)
  "Sort the Mac port menu by the last column clicked on.  Non-nil E contains the mouse event."
  (interactive (list last-input-event))
  (and e
       (let* ((pos (event-start e))
	      (obj (posn-object pos))
	      (s (car macport-menu-sort-key)) ; selector
	      (c (cdr macport-menu-sort-key)) ; comparator
	      (col (if obj (get-text-property (cdr obj) 'selector (car obj))
		     (get-text-property (posn-point pos) 'selector))))
	 (mouse-select-window e)
	 (if (eq s col)
	     (setcdr macport-menu-sort-key (if (eq c 'string-lessp) (lambda (x y) (string-lessp y x)) 'string-lessp))
	   (setq macport-menu-sort-key (cons col 'string-lessp)))
	 (macport-list-internal))))

;;;###autoload
(defun macport-list-no-fetch ()
  "Display a list of Mac ports in buffer named `\\[macport-buf]'.
Do not fetch the updated list of ports before displaying."
  (interactive)
  (with-current-buffer (macport-list-internal)
    (macport-menu-mode)
    ;; Set up the header line.
    (setq header-line-format
	  (mapconcat
	   (lambda (c)
	     (let ((name (car c))
		   (column (car (cdr c)))
		   (sf (car (cdr (cdr c))))
		   (he (car (cdr (cdr (cdr c))))))
	       (concat
		;; Insert a space that aligns the button properly.
		(propertize " "
			    'display (list 'space :align-to column)
			    'face 'fixed-pitch)
		;; Set up the column button.
		(propertize name
			    'column-name name
			    'help-echo he
			    'mouse-face 'highlight
			    'keymap macport-menu-sort-button-map
			    'selector sf))))
	   macport-columns
	   ""))
    (pop-to-buffer (current-buffer))))

;;;###autoload
(defun macport-list ()
  "Display a list of Mac ports in buffer named `\\[macport-buf]'.
Fetch the updated list of Mac ports before displaying."
  (interactive)
  (macport-refresh)
  (macport-list-no-fetch))

;; Make it appear on the menu.
(if (boundp 'menu-bar-options-menu)
    (define-key-after menu-bar-options-menu [macport]
      '(menu-item "Manage Mac Ports" macport-list
		  :help "Install or uninstall additional Mac ports")))



(provide 'macport)

;;; macport.el ends here
