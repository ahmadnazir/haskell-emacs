;;; emacs-haskell.el --- write emacs extensions in haskell

;; Copyright (C) 2014 Florian Knupfer

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
;; email: (rot13 "sxahcsre@tznvy.pbz")

;;; Commentary:

;; Put this file into your load path and put (require 'haskell-emacs)
;; and (haskell-emacs-init) into your .emacs.  Afterwards just
;; populate your `haskell-emacs-dir' with code.

;;; Example:

;;; Code:

(defgroup haskell-emacs nil
  "FFI for using haskell in emacs."
  :group 'haskell)

(eval `(defcustom haskell-emacs-load-dir ,(file-name-directory load-file-name)
         "Directory with source code of HaskellEmacs.hs."
         :group 'haskell-emacs
         :type 'string))

(defcustom haskell-emacs-dir "~/.emacs.d/haskell-fun/"
  "Directory with haskell modules."
  :group 'haskell-emacs
  :type 'string)

(defcustom haskell-emacs-cores 2
  "Number of cores used for haskell Emacs."
  :group 'haskell-emacs
  :type 'integer)

(defvar he/response nil)
(defvar he/count 0)
(defvar he/table (make-hash-table))
(defvar he/proc nil)

(defun haskell-emacs-init ()
  "Initialize haskell FFI or reload it to reflect changed functions."
  (interactive)
  (unless (file-directory-p haskell-emacs-dir)
    (mkdir haskell-emacs-dir t))
  (let ((funs (directory-files haskell-emacs-dir nil "^[^.].*\.hs$"))
        (process-connection-type nil)
        (imports)
        (exports)
        (arity-list)
        (code (with-temp-buffer
                (insert-file-contents
                 (concat haskell-emacs-load-dir "HaskellEmacs.hs"))
                (buffer-string))))
    (when he/proc
      (delete-process he/proc))
    (setq imports (apply 'concat
                         (mapcar (lambda (f)
                                   (let ((ex (he/exports-get f)))
                                     (when ex
                                       (add-to-list 'exports ex)
                                       (concat "import qualified "
                                               (substring f 0 -3) "\n"))))
                                 funs))
          arity-list (he/arity code imports (he/arity-format exports)))
    (he/compile code imports (he/exports-format exports arity-list))
    (setq he/proc (start-process "hask" nil
                                 (concat haskell-emacs-dir ".HaskellEmacs")))
    (set-process-query-on-exit-flag he/proc nil)
    (set-process-filter he/proc 'he/filter)
    (mapc (lambda (fi)
            (mapc (lambda (fu)
                    (eval (he/fun-wrapper
                           fu
                           (let ((arity (pop arity-list))
                                 (args))
                             (if (equal 0 arity)
                                 "()"
                               (dotimes (c arity (concat "(" args ")"))
                                 (setq args (concat args " x"
                                                    (number-to-string c)))))))))
                  fi))
          exports)))

(defun he/filter (process output)
  "Haskell PROCESS filter for OUTPUT from functions."
  (setq he/response (concat he/response output))
  (let* ((header (read he/response))
         (headLen (length (format "%s" header))))
    (while (<= (+ (car header) headLen)
               (length he/response))
      (let ((content (substring he/response headLen (+ headLen (car header)))))
        (setq he/response (substring he/response (+ headLen (car header))))
        (unless (car (last header))
          (error content))
        (puthash (cadr header) content he/table)
        (when (> (length he/response) 7)
          (setq header (read he/response)
                headLen (length (format "%s" header))))))))

(defun he/fun-body (fun args)
  "Generate function body for FUN with ARGS."
  (let ((arguments))
    (setq he/count (+ 1 he/count))
    (if (not args)
        (setq arguments "0")
      (setq arguments
            (mapcar
             (lambda (ARG)
               (if (stringp ARG)
                   (format "%S" (substring-no-properties ARG))
                 (if (or (listp ARG) (arrayp ARG))
                     (concat "("
                             (apply 'concat
                                    (mapcar (lambda (x)
                                              (concat (format "%S" x) "\n"))
                                            (he/array-to-list ARG))) ")")
                   (format "%S" ARG))))
             args))
      (if (equal 1 (length arguments))
          (setq arguments (car arguments))
        (setq arguments (mapcar (lambda (x) (concat x " ")) arguments))
        (setq arguments (concat "(" (apply 'concat arguments) ")"))))
    (process-send-string
     he/proc (concat fun " " (number-to-string he/count) " "
                     (number-to-string
                      (with-temp-buffer (insert arguments)
                                        (let ((lines 1))
                                          (goto-char (point-min))
                                          (while (re-search-forward "\n" nil t)
                                            (setq lines (+ lines 1)))
                                          lines)))
                     "\n" arguments "\n"))))

(defun he/fun-wrapper (fun args)
  "Take FUN with ARGS and return wrappers in elisp."
  (let ((body `(he/fun-body ,fun ,(read (concat "(list " (substring args 1))))))
    `(progn (byte-compile (defun ,(intern fun) ,(read args)
                            ,body (he/get he/count)))
            (byte-compile (defun ,(intern (concat fun "-async")) ,(read args)
                            ,body `(he/get ,he/count))))))

(defun he/get (id)
  "Retrieve result from haskell process with ID."
  (while (not (gethash id he/table))
    (accept-process-output he/proc))
  (read (gethash id he/table)))

(defun he/array-to-list (array)
  "Take a sequence and turn all ARRAY to lists."
  (mapcar (lambda (x) (if (and (not (stringp x)) (or (arrayp x) (listp x)))
                          (he/array-to-list x) x))
          array))

(defun he/arity-format (list-of-exports)
  "Take a LIST-OF-EXPORTS and format it into an arity check."
  (let* ((tr '(mapcar (lambda (y) (concat "arity "y",")) x))
         (result (apply 'concat (mapcar (lambda (x) (apply 'concat (eval tr)))
                                        list-of-exports))))
    (if (> (length result) 0)
        (substring result 0 -1)
      "")))

(defun he/exports-format (list-of-exports list-of-arity)
  "Format LIST-OF-EXPORTS and LIST-OF-ARITY into haskell syntax."
  (let* ((tr '(mapcar
               (lambda (y)
                 (let ((arity (pop list-of-arity))
                       (args) (args2))
                   (concat "(\""y"\",transform "
                           (case arity
                             (0 (concat "((const :: a -> Int -> a) " y ")"))
                             (1 y)
                             (t (concat
                                 "(\\\\"
                                 (dotimes (c arity (concat "(" (substring args 1)
                                                           ") -> " y " " args2))
                                   (setq args (concat args ",x"
                                                      (number-to-string c))
                                         args2 (concat args2 " x"
                                                       (number-to-string c))))
                                 ")")))
                           "),")))
               x))
         (result (apply 'concat (mapcar (lambda (x) (apply 'concat (eval tr)))
                                        list-of-exports))))
    (if (> (length result) 0)
        (substring result 0 -1)
      "")))

(defun he/exports-get (file)
  "Get a list of exports from FILE."
  (let ((f-base (file-name-base file))
        (w "[ \t\n\r]"))
    (with-temp-buffer
      (insert-file-contents (concat haskell-emacs-dir file))
      (when (re-search-forward
             (concat "^module" w "+" f-base
                     w "*(" w "*\\(\\(?:[^)]\\|" w "\\)+\\)" w "*)")
             nil t)
        (mapcar (lambda (fun) (concat f-base "."
                                      (car (last (split-string fun "\\.")))))
                (split-string (match-string 1) "[ \n\r,]+"))))))

(defun he/compile (code import export)
  "Inject into CODE a list of IMPORT and of EXPORT and compile it."
  (with-temp-buffer
    (let ((heF ".HaskellEmacs.hs")
          (heB "*HASKELL-BUFFER*"))
      (insert code)
      (goto-char (point-min))
      (when (re-search-forward "---- <<import>> ----" nil t)
        (replace-match import))
      (when (re-search-forward "---- <<export>> ----" nil t)
        (replace-match export))
      (cd haskell-emacs-dir)
      (unless (and (file-exists-p heF)
                   (equal (buffer-string)
                          (with-temp-buffer (insert-file-contents heF)
                                            (buffer-string))))
        (write-file heF))
      (unless
          (eql 0 (call-process "ghc" nil heB nil
                               "-O2" "-threaded" "--make"
                               (concat "-with-rtsopts=-N"
                                       (number-to-string haskell-emacs-cores))
                               heF))
        (let ((bug (with-current-buffer heB (buffer-string))))
          (kill-buffer heB)
          (error bug)))
      (kill-buffer heB))))

(defun he/arity (code import export)
  "Inject into CODE a list of IMPORT and of EXPORT and return a list of arity."
  (with-temp-buffer
    (let ((heF ".HaskellEmacsA.hs")
          (heB "*HASKELL-BUFFER-A*"))
      (insert code)
      (goto-char (point-min))
      (when (re-search-forward "---- <<import>> ----" nil t)
        (replace-match import))
      (when (re-search-forward "---- <<arity>> ----" nil t)
        (replace-match export))
      (cd haskell-emacs-dir)
      (unless (and (file-exists-p heF)
                   (equal (buffer-string)
                          (with-temp-buffer (insert-file-contents heF)
                                            (buffer-string))))
        (write-file heF))
      (unless (eql 0 (call-process "ghc" nil heB nil "--make" heF))
        (let ((bug (with-current-buffer heB (buffer-string))))
          (kill-buffer heB)
          (error bug)))
      (kill-buffer heB)
      (with-temp-buffer
        (call-process (concat haskell-emacs-dir ".HaskellEmacsA") nil t)
        (read (buffer-string))))))

(provide 'haskell-emacs)

;;; haskell-emacs.el ends here
