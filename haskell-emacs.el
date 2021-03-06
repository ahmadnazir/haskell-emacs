;;; haskell-emacs.el --- Write emacs extensions in haskell

;; Copyright (C) 2014-2015 Florian Knupfer

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA

;; Author: Florian Knupfer
;; Email: fknupfer@gmail.com
;; Keywords: haskell, emacs, ffi
;; URL: https://github.com/knupfer/haskell-emacs

;;; Commentary:

;; haskell-emacs is a library which allows extending emacs in haskell.
;; It provides an FFI (foreign function interface) for haskell functions.

;; Run `haskell-emacs-init' or put it into your .emacs.  Afterwards just
;; populate your `haskell-emacs-dir' with haskell modules, which
;; export functions.  These functions will be wrapped automatically into
;; an elisp function with the name Module.function.

;; See documentation for `haskell-emacs-init' for a detailed example
;; of usage.

;;; Code:
(defgroup haskell-emacs nil
  "FFI for using haskell in emacs."
  :group 'haskell)

(defcustom haskell-emacs-dir "~/.emacs.d/haskell-fun/"
  "Directory with haskell modules."
  :group 'haskell-emacs
  :type 'string)

(defcustom haskell-emacs-ghc-flags '("-O2" "-threaded" "--make"
                                     "-with-rtsopts=-N")
  "Flags which are used for compilation."
  :group 'haskell-emacs
  :type '(repeat string))

(defcustom haskell-emacs-nix-shell-args
  '("-p")
  "Environment used to compile the modules when on an nixos machine."
  :group 'haskell-emacs
  :type '(repeat string))

(defcustom haskell-emacs-ghc-executable "ghc"
  "Executable used for compilation."
  :group 'haskell-emacs
  :type 'string)

(defconst haskell-emacs--api-hash
  (with-temp-buffer
    (insert-file-contents load-file-name)
    (insert-file-contents
     (concat (file-name-directory load-file-name) "HaskellEmacs.hs"))
    (sha1 (buffer-string))))
(defvar haskell-emacs--count 0)
(defvar haskell-emacs--function-hash nil)
(defvar haskell-emacs--fun-list nil)
(defvar haskell-emacs--is-nixos
  (when (eq system-type 'gnu/linux)
    (string-match " nixos " (shell-command-to-string "uname -a"))))
(defvar haskell-emacs--load-dir (file-name-directory load-file-name))
(defvar haskell-emacs--module-list nil)
(defvar haskell-emacs--proc nil)
(defvar haskell-emacs--response nil)
(defvar haskell-emacs--table (make-hash-table))

(defun haskell-emacs--search-modules ()
  "Search haskell-emacs modules in the `load-path'."
  (let ((modules))
    (mapc (lambda (x)
            (when (file-directory-p x)
              (mapc (lambda (y) (add-to-list 'modules (file-name-directory y)))
                    (directory-files x t "^haskell-emacs-.*\.el"))))
            load-path)
    modules))

;;;###autoload
(defun haskell-emacs-init (&optional arg)
  "Initialize haskell FFI or reload it to reflect changed functions.

When ARG is not nil or `haskell-emacs-init' is called
interactively and `haskell-emacs-dir' doesn't exist, ask an
installation dialog.  It will try to wrap all exported functions
within `haskell-emacs-dir' into an synchronous and an
asynchronous elisp function.

Dependencies:
 - GHC
 - cabal

Haskell packages:
 - atto-lisp
 - parallel
 - utf8-string

Consider that you've got the following toy program:

---- ~/.emacs.d/haskell-fun/Matrix.hs
module Matrix (identity,isIdentity,dyadic,transpose) where

import qualified Data.List as L

-- | Takes a matrix (a list of lists of ints) and returns its transposition.
transpose :: [[Int]] -> [[Int]]
transpose = L.transpose

-- | Returns an identity matrix of size n.
identity :: Int -> [[Int]]
identity n
  | n > 1 = L.nub $ L.permutations $ 1 : replicate (n-1) 0
  | otherwise = [[1]]

-- | Check whether a given matrix is a identity matrix.
isIdentity :: [[Int]] -> Bool
isIdentity xs = xs == identity (length xs)

-- | Compute the dyadic product of two vectors.
dyadic :: [Int] -> [Int] -> [[Int]]
dyadic xs ys = map (\\x -> map (x*) ys) xs
----

Now call `haskell-emacs-init' to provide the elisp wrappers.

  (Matrix.transpose '((1 2) (3 4) (5 6)))
    => ((1 3 5) (2 4 6))

  (Matrix.dyadic '(1 2 3) '(4 5 6))
    => ((4 5 6) (8 10 12) (12 15 18))

If you provide bad input, a description of the type error will be
shown to you.

If you call the async pendant of your functions, you'll get a
future which will block on evaluation if the result is not already present.

  (Matrix.transpose-async '((1 2) (3 4) (5 6)))
    => (haskell-emacs--get 7)

  (eval (haskell-emacs--get 7))
    => ((1 3 5) (2 4 6))

Or perhaps more convenient:

  (let ((tr (Matrix.transpose-async '((1 2) (3 4) (5 6)))))

       ;; other elisp stuff, or more asyncs

       (eval tr))

Haskell-emacs can handle functions of arbitrary arity (including
0), but you should note, that only monomorphic functions are
supported, and only about ten different types.

Functions that take only one argument will be fused on Emacs
side, this allows executing a chain of functions asynchronously:

  (let ((result (Matrix.transpose-async (Matrix.transpose '((1 2) (3 4))))))

    ;; other stuff

    (eval result))
     => ((1 2) (3 4))

Furthermore, it nullifies the small performance overhead (0.07 ms
per function call) between fused functions which allows more
modularity and using haskell for even more basic tasks.

If you want to distribute a haskell library for haskell-emacs,
just write an elisp file describing the package and the
corresponding haskell file in the same dir:

  ;;;; haskell-emacs-pi/haskell-emacs-pi.el

  ;;; haskell-emacs-pi.el --- return pi

  ;; Version: 1.0.0
  ;; Package-Requires: ((haskell-emacs \"2.4.0\"))

  ;;; Code:

  (require 'haskell-emacs)
  (provide 'haskell-emacs-pi)

  ;;; haskell-emacs-pi.el ends here


  ---- haskell-emacs-pi/Pi.hs

  module Pi where (piSquare)

  piSquare :: Double
  piSquare = pi^2

  ----

That's all.  You can distribute this package for example via
melpa (don't forget to add the *.hs to the files of the recipe)
or just point your `load-path' to this directory.  If you call
afterwards `haskell-emacs-init', it will automatically find this
module and provide the functions.

If you want to use such functions in your elisp library, do the following:

  ;;; my-nums.el --- add a number to the square of pi

  ;; Package-Requires: ((haskell-emacs-pi \"1.0.0\"))

  ;;; Code:

  (require 'haskell-emacs-pi)
  (eval-when-compile (haskell-emacs-init))

  ;;;### autoload
  (defun my-nums (arg)
    (+ arg (Pi.piSquare)))

  ;;; my-nums.el ends here."
  (interactive "p")
  (setq haskell-emacs--module-list (haskell-emacs--search-modules))
  (let* ((first-time (unless (file-directory-p haskell-emacs-dir)
                       (mkdir haskell-emacs-dir t)
                       (when arg (haskell-emacs--install-dialog))))
         (funs (apply 'append
                      (mapcar (lambda (x) (directory-files x t "^[^.].*\.hs$"))
                              (apply 'list haskell-emacs-dir
                                     haskell-emacs--module-list))))
         (process-connection-type nil)
         (arity-list)
         (docs)
         (heF ".HaskellEmacs.hs")
         (heE (concat haskell-emacs-dir ".HaskellEmacs"
                      (when (eq system-type 'windows-nt) ".exe")))
         (code (with-temp-buffer
                 (insert-file-contents
                  (concat haskell-emacs--load-dir "HaskellEmacs.hs"))
                 (buffer-string)))
         (stop-proc '(when haskell-emacs--proc
                       (set-process-sentinel haskell-emacs--proc nil)
                       (delete-process haskell-emacs--proc)))
         (start-proc '(progn
                        (setq haskell-emacs--proc
                              (start-process "hask" nil heE))
                        (set-process-filter haskell-emacs--proc
                                            'haskell-emacs--filter))))
    (eval stop-proc)
    (setq haskell-emacs--response nil)
    (setq haskell-emacs--function-hash
          (with-temp-buffer (mapc 'insert-file-contents funs)
                            (sha1 (buffer-string))))
    (unless
        (and (file-exists-p heE)
             (with-temp-buffer
               (insert-file-contents (concat haskell-emacs-dir heF))
               (and (re-search-forward haskell-emacs--api-hash nil t)
                    (re-search-forward haskell-emacs--function-hash nil t))))
      (haskell-emacs--compile code))
    (eval start-proc)
    (setq funs (mapcar (lambda (f) (with-temp-buffer
                                     (insert-file-contents f)
                                     (buffer-string)))
                       funs)
          docs (apply 'concat funs)
          funs (haskell-emacs--fun-body 'allExports (apply 'list "" "" funs))
          docs (haskell-emacs--fun-body
                'getDocumentation
                (list (mapcar (lambda (x) (cadr (split-string x "\\.")))
                              (cadr funs))
                      docs)))
    (dotimes (a 2)
      (setq arity-list (haskell-emacs--fun-body 'arityList '(0)))
      (haskell-emacs--compile
       (haskell-emacs--fun-body
        'formatCode
        (list (list (car funs)
                    (car arity-list)
                    (haskell-emacs--fun-body 'arityFormat
                                             (car (cdr funs))))
              code))))
    (let ((arity (cadr arity-list))
          (table-of-funs (make-hash-table :test 'equal)))
      (mapc (lambda (func)
              (let ((id (car (split-string func "\\."))))
                (puthash id
                         (concat (gethash id table-of-funs)
                                 (format "%S" (haskell-emacs--fun-wrapper
                                               (read func)
                                               (read (pop arity))
                                               (pop docs))))
                         table-of-funs)))
            (cadr funs))
      (maphash (lambda (key value)
                 (with-temp-buffer
                   (let ((buffer-file-name (concat haskell-emacs-dir key ".hs")))
                     (insert value)
                     (eval-buffer))))
               table-of-funs))
    (if (equal first-time "example")
        (message
         "Now you can run the examples from C-h f haskell-emacs-init.
For example (Matrix.transpose '((1 2 3) (4 5 6)))")
      (if (equal first-time "no-example")
          (message
           "Now you can populate your `haskell-emacs-dir' with haskell modules.
Read C-h f haskell-emacs-init for more instructions")
        (message "Finished compiling haskell-emacs.")))))

(defun haskell-emacs--filter (process output)
  "Haskell PROCESS filter for OUTPUT from functions."
  (unless (= 0 (length haskell-emacs--response))
    (setq output (concat haskell-emacs--response output)
          haskell-emacs--response nil))
  (let ((header)
        (dataLen)
        (p))
    (while (and (setq p (string-match ")" output))
                (<= (setq header (read output)
                          dataLen (+ (car header) 1 p))
                    (length output)))
      (let ((content (substring output (- dataLen (car header)) dataLen)))
        (setq output (substring output dataLen))
        (when (= 3 (length header)) (error content))
        (puthash (cadr header) content haskell-emacs--table))))
  (unless (= 0 (length output))
    (setq haskell-emacs--response output)))

(defun haskell-emacs--fun-body (fun args)
  "Generate function body for FUN with ARGS."
  (process-send-string
   haskell-emacs--proc (format "%S" (cons fun args)))
  (haskell-emacs--get 0))

(defun haskell-emacs--optimize-ast (lisp)
    "Optimize the ast of LISP."
   (if (and (listp lisp)
              (member (car lisp) haskell-emacs--fun-list))
         (cons (car lisp) (mapcar 'haskell-emacs--optimize-ast (cdr lisp)))
       (eval lisp)))

(defun haskell-emacs--fun-wrapper (fun args docs)
  "Take FUN with ARGS and return wrappers in elisp with the DOCS."
  `(progn (add-to-list
           'haskell-emacs--fun-list
           (defmacro ,fun ,args
             ,docs
             `(progn (process-send-string
                      haskell-emacs--proc
                      (format "%S" (haskell-emacs--optimize-ast
                                    ',(cons ',fun (list ,@args)))))
                     (haskell-emacs--get 0))))
          (defmacro ,(read (concat (format "%s" fun) "-async")) ,args
            ,docs
            `(progn (process-send-string
                     haskell-emacs--proc
                     (format (concat (number-to-string
                                      (setq haskell-emacs--count
                                            (+ haskell-emacs--count 1))) "%S")
                             (haskell-emacs--optimize-ast
                              ',(cons ',fun (list ,@args)))))
                    (list 'haskell-emacs--get haskell-emacs--count)))))

(defun haskell-emacs--install-dialog ()
  "Run the installation dialog."
  (let ((sandbox (yes-or-no-p "Create a cabal sandbox? "))
        (install (yes-or-no-p "Cabal install the dependencies? "))
        (example (yes-or-no-p "Add a simple example? ")))
    (when sandbox
      (with-temp-buffer
        (message "Creating sandbox...")
        (cd haskell-emacs-dir)
        (unless (= 0 (call-process "cabal" nil t nil
                                   "sandbox"
                                   "init"))
          (error (buffer-string)))))
    (when install
      (with-temp-buffer
        (message "Installing dependencies...")
        (cd haskell-emacs-dir)
        (unless (= 0 (call-process "cabal" nil t nil
                                   "install"
                                   "atto-lisp"
                                   "parallel"
                                   "utf8-string"))
          (error (buffer-string)))))
    (if example
        (with-temp-buffer
          (insert "
module Matrix (identity,isIdentity,dyadic,transpose) where

import qualified Data.List as L

-- | Takes a matrix (a list of lists of ints) and returns its transposition.
transpose :: [[Int]] -> [[Int]]
transpose = L.transpose

-- | Returns an identity matrix of size n.
identity :: Int -> [[Int]]
identity n
  | n > 1 = L.nub $ L.permutations $ 1 : replicate (n-1) 0
  | otherwise = [[1]]

-- | Check whether a given matrix is a identity matrix.
isIdentity :: [[Int]] -> Bool
isIdentity xs = xs == identity (length xs)

-- | Compute the dyadic product of two vectors.
dyadic :: [Int] -> [Int] -> [[Int]]
dyadic xs ys = map (\\x -> map (x*) ys) xs")
          (write-file (concat haskell-emacs-dir "Matrix.hs"))
                          "example")
      "no-example")))

(defun haskell-emacs--get (id)
  "Retrieve result from haskell process with ID."
  (while (not (gethash id haskell-emacs--table))
    (accept-process-output haskell-emacs--proc))
  (let ((res (read (gethash id haskell-emacs--table))))
    (remhash id haskell-emacs--table)
    (if (and (listp res)
             (or (functionp (car res))
                 (macrop (car res))))
        (eval res)
      res)))

(defun haskell-emacs--find-package-db ()
  "Search for the package dir in a cabal sandbox."
  (let ((sandbox (concat haskell-emacs-dir ".cabal-sandbox")))
    (when (file-directory-p sandbox)
      (car (directory-files sandbox t "packages\.conf\.d$")))))

(defun haskell-emacs--compile (code)
  "Use CODE to compile a new haskell Emacs programm."
  (when haskell-emacs--proc
    (set-process-sentinel haskell-emacs--proc nil)
    (delete-process haskell-emacs--proc))
  (with-temp-buffer
    (let* ((heB "*HASKELL-BUFFER*")
           (heF ".HaskellEmacs.hs")
           (code (concat
                  "-- hash of haskell-emacs: " haskell-emacs--api-hash "\n"
                  "-- hash of all functions: " haskell-emacs--function-hash
                  "\n" code))
           (package-db (haskell-emacs--find-package-db))
           (haskell-emacs-ghc-flags
            (if package-db
                (cons (concat "-package-db=" package-db) haskell-emacs-ghc-flags)
              haskell-emacs-ghc-flags)))
      (cd haskell-emacs-dir)
      (unless (and (file-exists-p heF)
                   (equal code (with-temp-buffer (insert-file-contents heF)
                                                 (buffer-string))))
        (insert code)
        (write-file heF))
      (message "Compiling ...")
      (haskell-emacs--compile-command heF heB)))
  (setq haskell-emacs--proc
        (start-process "hask" nil
                       (concat haskell-emacs-dir ".HaskellEmacs"
                               (when (eq system-type 'windows-nt) ".exe"))))
  (set-process-filter haskell-emacs--proc 'haskell-emacs--filter)
  (set-process-query-on-exit-flag haskell-emacs--proc nil)
  (set-process-sentinel haskell-emacs--proc
                        (lambda (proc sign)
                          (let ((debug-on-error t))
                            (error "Haskell-emacs crashed")))))

(defun haskell-emacs--compile-command (heF heB)
  "Run the compilation for file HEF with buffer HEB."
  (let ((args (cons heF (if haskell-emacs--module-list
                            (cons (concat
                                   "-i"
                                   (substring
                                    (apply
                                     'concat
                                     (mapcar (lambda (x) (concat ":" x))
                                             haskell-emacs--module-list)) 1))
                                  haskell-emacs-ghc-flags)
                          haskell-emacs-ghc-flags))))
    (if (eql 0 (apply 'call-process (if haskell-emacs--is-nixos "nix-shell"
                                      haskell-emacs-ghc-executable)
                      nil heB nil
                      (if haskell-emacs--is-nixos
                          (append haskell-emacs-nix-shell-args
                                  (list
                                   "--command"
                                   (apply 'concat haskell-emacs-ghc-executable
                                          (mapcar (lambda (x) (concat " " x))
                                                  args))))
                        args)))
        (kill-buffer heB)
      (let ((bug (with-current-buffer heB (buffer-string))))
        (kill-buffer heB)
        (error bug)))))

(provide 'haskell-emacs)

;;; haskell-emacs.el ends here
