;;;; SWANK support for CLISP.

;;;; Copyright (C) 2003, 2004 W. Jenkner, V. Sedach

;;;; swank-clisp.lisp is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU General Public License as
;;;; published by the Free Software Foundation; either version 2, or
;;;; (at your option) any later version.

;;; This is work in progress, but it's already usable.  Many things
;;; are adapted from other swank-*.lisp, in particular from
;;; swank-allegro (I don't use allegro at all, but it's the shortest
;;; one and I found Helmut Eller's code there enlightening).

;;; This code is developed using the current CVS version of CLISP and
;;; CLISP 2.32 on Linux. Older versions may not work (2.29 and below
;;; are confirmed non-working; please upgrade).  You need an image
;;; containing the "SOCKET", "REGEXP", and "LINUX" packages.  The
;;; portable xref from the CMU AI repository and metering.lisp from
;;; CLOCC [1] are also required (alternatively, you have to manually
;;; comment out some code below). 
;;;
;;; [1] http://cvs.sourceforge.net/viewcvs.py/clocc/clocc/src/tools/metering/

(in-package :swank-backend)

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;;(use-package "SOCKET")
  (use-package "GRAY"))

(eval-when (:compile-toplevel :execute)
  (when (find-package "LINUX")
    (pushnew :linux *features*)))

;;;; if this listp has the complete CLOS then we use it, othewise we
;;;; build up a "fake" swank-mop and then overide the methods in the
;;;; inspector.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *have-mop*
    (and (find-package :clos)
         (eql :external
              (nth-value 1 (find-symbol (string ':standard-slot-definition) :clos))))
    "True in those CLISP imagse which have a complete MOP implementation."))

#+#.(cl:if swank-backend::*have-mop* '(cl:and) '(cl:or))
(progn
  (import-to-swank-mop
   '( ;; classes
     cl:standard-generic-function
     clos:standard-slot-definition
     cl:method
     cl:standard-class
     clos::eql-specializer
     ;; standard-class readers
     clos:class-default-initargs
     clos:class-direct-default-initargs
     clos:class-direct-slots
     clos:class-direct-subclasses
     clos:class-direct-superclasses
     clos:class-finalized-p
     cl:class-name
     clos:class-precedence-list
     clos:class-prototype
     clos:class-slots
     clos:specializer-direct-methods
     ;; eql-specializer accessors
     clos::eql-specializer-object
     ;; generic function readers
     clos:generic-function-argument-precedence-order
     clos:generic-function-declarations
     clos:generic-function-lambda-list
     clos:generic-function-methods
     clos:generic-function-method-class
     clos:generic-function-method-combination
     clos:generic-function-name
     ;; method readers
     clos:method-generic-function
     clos:method-function
     clos:method-lambda-list
     clos:method-specializers
     clos:method-qualifiers
     ;; slot readers
     clos:slot-definition-allocation
     clos:slot-definition-initargs
     clos:slot-definition-initform
     clos:slot-definition-initfunction
     clos:slot-definition-name
     clos:slot-definition-type
     clos:slot-definition-readers
     clos:slot-definition-writers))
  
  (defun swank-mop:slot-definition-documentation (slot)
    (clos::slot-definition-documentation slot)))

#-#.(cl:if swank-backend::*have-mop* '(and) '(or))
(defclass swank-mop:standard-slot-definition ()
  ()
  (:documentation "Dummy class created so that swank.lisp will compile and load."))

#+linux
(defmacro with-blocked-signals ((&rest signals) &body body)
  (ext:with-gensyms ("SIGPROCMASK" ret mask)
    `(multiple-value-bind (,ret ,mask)
	 (linux:sigprocmask-set-n-save
	  ,linux:SIG_BLOCK
	  ,(do ((sigset (linux:sigset-empty)
			(linux:sigset-add sigset (the fixnum (pop signals)))))
	       ((null signals) sigset)))
       (linux:check-res ,ret 'linux:sigprocmask-set-n-save)
       (unwind-protect
	    (progn ,@body)
	 (linux:sigprocmask-set ,linux:SIG_SETMASK ,mask nil)))))

;; XXX currently only works in CVS version. 2.32 breaks.
;; #+linux
;; (defimplementation call-without-interrupts (fn)
;;   (with-blocked-signals (#.linux:SIGINT) (funcall fn)))
;; 
;; #-linux
(defimplementation call-without-interrupts (fn)
  (funcall fn))

#+unix (defmethod getpid () (system::program-id))
#+win32 
(defmethod getpid ()
  (cond ((find-package :win32)
	 (funcall (find-symbol "GetCurrentProcessId" :win32)))
	(t
	 (system::getenv "PID"))))

;; the above is likely broken; we need windows NT users!

(defimplementation lisp-implementation-type-name ()
  "clisp")

(defimplementation set-default-directory (directory)
  (setf (ext:default-directory) directory)
  (namestring (setf *default-pathname-defaults* (ext:default-directory))))


;;; TCP Server

(defimplementation create-socket (host port)
  (declare (ignore host))
  (socket:socket-server port))

(defimplementation local-port (socket)
  (socket:socket-server-port socket))

(defimplementation close-socket (socket)
  (socket:socket-server-close socket))

(defimplementation accept-connection (socket)
  (socket:socket-accept socket
			:buffered nil ;; XXX should be t
			:element-type 'character
			:external-format (ext:make-encoding 
					  :charset 'charset:iso-8859-1
					  :line-terminator :unix)))

;;; Swank functions

(defimplementation arglist (fname)
  (block nil
    (or (ignore-errors (return (ext:arglist fname)))
	:not-available)))

(defimplementation macroexpand-all (form)
  (ext:expand-form form))

(defimplementation describe-symbol-for-emacs (symbol)
  "Return a plist describing SYMBOL.
Return NIL if the symbol is unbound."
  (let ((result ()))
    (labels ((doc (kind)
	       (or (documentation symbol kind) :not-documented))
	     (maybe-push (property value)
	       (when value
		 (setf result (list* property value result)))))
      (when (fboundp symbol)
	(if (macro-function symbol)
	    (setf (getf result :macro) (doc 'function))
	    (setf (getf result :function) (doc 'function))))
      (maybe-push :variable (when (boundp symbol) (doc 'variable)))
      (maybe-push :class (when (find-class symbol nil) 
			   (doc 'type))) ;this should be fixed
      result)))

(defimplementation describe-definition (symbol namespace)
  (ecase namespace
    (:variable (describe symbol))
    (:macro (describe (macro-function symbol)))
    (:function (describe (symbol-function symbol)))
    (:class (describe (find-class symbol)))))

(defun fspec-pathname (symbol)
  (let ((path (getf (gethash symbol sys::*documentation*) 'sys::file)))
    (if (and path
	     (member (pathname-type path)
		     custom:*compiled-file-types* :test #'string=))
	(loop for suffix in custom:*source-file-types*
	      thereis (make-pathname :defaults path :type suffix))
	path)))

(defun fspec-location (fspec)
  (let ((file (fspec-pathname fspec)))
    (cond (file
	   (multiple-value-bind (truename c) (ignore-errors (truename file))
	     (cond (truename 
		    (make-location (list :file (namestring truename))
				   (list :function-name (string fspec))))
		   (t (list :error (princ-to-string c))))))
	  (t (list :error (format nil "No source information available for: ~S"
				  fspec))))))

(defimplementation find-definitions (name)
  (list (list name (fspec-location name))))

(defvar *sldb-topframe*)
(defvar *sldb-botframe*)
(defvar *sldb-source*)
(defvar *sldb-debugmode* 4)

(defun frame-down (frame)
  (sys::frame-down-1 frame sys::*debug-mode*))

(defun frame-up (frame)
  (sys::frame-up-1 frame sys::*debug-mode*))

(defimplementation call-with-debugging-environment (debugger-loop-fn)
  (let* ((sys::*break-count* (1+ sys::*break-count*))
	 (sys::*driver* debugger-loop-fn)
	 (sys::*fasoutput-stream* nil)
	 (sys::*frame-limit1* (sys::frame-limit1 0))
	 (sys::*frame-limit2* (sys::frame-limit2))
	 (sys::*debug-mode* *sldb-debugmode*)
	 (*sldb-topframe* sys::*frame-limit1*))
    (funcall debugger-loop-fn)))

(defun nth-frame (index)
  (loop for frame = *sldb-topframe* then (frame-up frame)
	repeat index
	finally (return frame)))

(defimplementation compute-backtrace (start end)
  (let ((end (or end most-positive-fixnum)))
    (loop for last = nil then frame
	  for frame = (nth-frame start) then (frame-up frame)
	  for i from start below end
	  until (or (eq frame last) (system::driver-frame-p frame))
	  collect frame)))

(defimplementation print-frame (frame stream)
  (write-string (string-left-trim '(#\Newline)
				  (with-output-to-string (stream)
				    (sys::describe-frame stream frame)))
		stream))

(defimplementation eval-in-frame (form frame-number)
  (sys::eval-at (nth-frame frame-number) form))

(defimplementation frame-locals (frame-number)
  (let* ((frame (nth-frame frame-number))
	 (frame-env (sys::eval-at frame '(sys::the-environment))))
    (append
     (frame-do-venv frame (svref frame-env 0))
     (frame-do-fenv frame (svref frame-env 1))
     (frame-do-benv frame (svref frame-env 2))
     (frame-do-genv frame (svref frame-env 3))
     (frame-do-denv frame (svref frame-env 4)))))

(defimplementation frame-var-value (frame var)
  (getf (nth var (frame-locals frame)) :value))

;; Interpreter-Variablen-Environment has the shape
;; NIL or #(v1 val1 ... vn valn NEXT-ENV).

(defun frame-do-venv (frame venv)
  (loop for i from 1 below (length venv) by 2
	as symbol = (svref venv (1- i))
	and value = (svref venv i)
	collect (list :name symbol :id 0
		      :value (if (eq sys::specdecl value)
                                 ;; special variable
                                 (sys::eval-at frame symbol)
                                 ;; lexical variable or symbol macro
                                 value))))

(defun frame-do-fenv (frame fenv)
  (declare (ignore frame fenv))
  nil)

(defun frame-do-benv (frame benv)
  (declare (ignore frame benv))
  nil)

(defun frame-do-genv (frame genv)
  (declare (ignore frame genv))
  nil)

(defun frame-do-denv (frame denv)
  (declare (ignore frame denv))
  nil)

(defimplementation frame-catch-tags (index)
  (declare (ignore index))
  nil)

(defimplementation return-from-frame (index form)
  (sys::return-from-eval-frame (nth-frame index) form))

(defimplementation restart-frame (index)
  (sys::redo-eval-frame (nth-frame index)))

(defimplementation frame-source-location-for-emacs (index)
  (let ((f (nth-frame index)))
    (list :error (format nil "Cannot find source for frame: ~A ~A ~A" 
			 f
			 (sys::eval-frame-p f)
			 (sys::the-frame)))))

;;; Profiling

(defimplementation profile (fname)
  (eval `(mon:monitor ,fname)))		;monitor is a macro

(defimplementation profiled-functions ()
  mon:*monitored-functions*)

(defimplementation unprofile (fname)
  (eval `(mon:unmonitor ,fname)))	;unmonitor is a macro

(defimplementation unprofile-all ()
  (mon:unmonitor))

(defimplementation profile-report ()
  (mon:report-monitoring))

(defimplementation profile-reset ()
  (mon:reset-all-monitoring))

(defimplementation profile-package (package callers-p methods)
  (declare (ignore callers-p methods))
  (mon:monitor-all package))

;;; Handle compiler conditions (find out location of error etc.)

(defmacro compile-file-frobbing-notes ((&rest args) &body body)
  "Pass ARGS to COMPILE-FILE, send the compiler notes to
*STANDARD-INPUT* and frob them in BODY."
  `(let ((*error-output* (make-string-output-stream))
	 (*compile-verbose* t))
     (multiple-value-prog1
      (compile-file ,@args)
      (handler-case  
       (with-input-from-string
	(*standard-input* (get-output-stream-string *error-output*))
	,@body)
       (sys::simple-end-of-file () nil)))))

(defvar *orig-c-warn* (symbol-function 'system::c-warn))
(defvar *orig-c-style-warn* (symbol-function 'system::c-style-warn))
(defvar *orig-c-error* (symbol-function 'system::c-error))
(defvar *orig-c-report-problems* (symbol-function 'system::c-report-problems))

(defmacro dynamic-flet (names-functions &body body)
  "(dynamic-flet ((NAME FUNCTION) ...) BODY ...)
Execute BODY with NAME's funtion slot set to FUNCTION."
  `(ext:letf* ,(loop for (name function) in names-functions
		     collect `((symbol-function ',name) ,function))
    ,@body))
 
(defun compiler-note-location ()
  "Return the current compiler location."
  (let ((lineno1 sys::*compile-file-lineno1*)
	(lineno2 sys::*compile-file-lineno2*)
	(file sys::*compile-file-truename*))
    (cond ((and file lineno1 lineno2)
	   (make-location (list ':file (namestring file))
			  (list ':line lineno1)))
	  (*buffer-name*
	   (make-location (list ':buffer *buffer-name*) 
			  (list ':position *buffer-offset*)))
	  (t
	   (list :error "No error location available")))))

(defun signal-compiler-warning (cstring args severity orig-fn)
  (signal (make-condition 'compiler-condition
			  :severity severity
			  :message (apply #'format nil cstring args)
			  :location (compiler-note-location)))
  (apply orig-fn cstring args))

(defun c-warn (cstring &rest args)
  (signal-compiler-warning cstring args :warning *orig-c-warn*))

(defun c-style-warn (cstring &rest args)
  (dynamic-flet ((sys::c-warn *orig-c-warn*))
    (signal-compiler-warning cstring args :style-warning *orig-c-style-warn*)))

(defun c-error (cstring &rest args)
  (signal-compiler-warning cstring args :error *orig-c-error*))

(defimplementation call-with-compilation-hooks (function)
  (handler-bind ((warning #'handle-notification-condition))
    (dynamic-flet ((system::c-warn #'c-warn)
		   (system::c-style-warn #'c-style-warn)
		   (system::c-error #'c-error))
      (funcall function))))

(defun handle-notification-condition (condition)
  "Handle a condition caused by a compiler warning."
  (signal (make-condition 'compiler-condition
			  :original-condition condition
			  :severity :warning
			  :message (princ-to-string condition)
			  :location (compiler-note-location))))

(defvar *buffer-name* nil)
(defvar *buffer-offset*)

(defimplementation swank-compile-file (filename load-p)
  (with-compilation-hooks ()
    (with-compilation-unit ()
      (let ((fasl-file (compile-file filename)))
	(when (and load-p fasl-file)
	  (load fasl-file))
	nil))))

(defimplementation swank-compile-string (string &key buffer position directory)
  (declare (ignore directory))
  (with-compilation-hooks ()
    (let ((*buffer-name* buffer)
	  (*buffer-offset* position))
      (funcall (compile nil (read-from-string
                             (format nil "(~S () ~A)" 'lambda string)))))))

;;; Portable XREF from the CMU AI repository.

(setq pxref::*handle-package-forms* '(cl:in-package))

(defmacro defxref (name function)
  `(defimplementation ,name (name)
    (xref-results (,function name))))

(defxref who-calls      pxref:list-callers)
(defxref who-references pxref:list-readers)
(defxref who-binds      pxref:list-setters)
(defxref who-sets       pxref:list-setters)
(defxref list-callers   pxref:list-callers)
(defxref list-callees   pxref:list-callees)

(defun xref-results (symbols)
  (let ((xrefs '()))
    (dolist (symbol symbols)
      (push (list symbol (fspec-location symbol)) xrefs))
    xrefs))

(when (find-package :swank-loader)
  (setf (symbol-function (intern "USER-INIT-FILE" :swank-loader))
	(lambda ()
	  (let ((home (user-homedir-pathname)))
	    (and (ext:probe-directory home)
		 (probe-file (format nil "~A/.swank.lisp"
				     (namestring (truename home)))))))))

;; Don't set *debugger-hook* to nil on break.
(ext:without-package-lock () 
 (defun break (&optional (format-string "Break") &rest args)
   (if (not sys::*use-clcs*)
       (progn
	 (terpri *error-output*)
	 (apply #'format *error-output*
		(concatenate 'string "*** - " format-string)
		args)
	 (funcall ext:*break-driver* t))
       (let ((condition
	      (make-condition 'simple-condition
			      :format-control format-string
			      :format-arguments args))
	     ;;(*debugger-hook* nil)
	     ;; Issue 91
	     )				
	 (ext:with-restarts
	     ((continue
	       :report (lambda (stream)
			 (format stream (sys::text "Return from ~S loop")
				 'break))
	       ()))
	   (with-condition-restarts condition (list (find-restart 'continue))
				    (invoke-debugger condition)))))
   nil))

(in-package :system)

#.(setf (ext:package-lock :system) nil)

(ext:without-package-lock () 

;; Patch buggy format parser.  ~:,D was not parsed correcly.
(defun format-parse-cs (control-string startindex csdl stop-at)
  (declare (fixnum startindex))
  (macrolet ((errorstring ()
               (TEXT "The control string terminates within a format directive.")))
    (prog* ((index startindex)  ; cs-index of the next character
            ch                  ; current character
            intparam            ; Integer-Parameter
            newcsd              ; current CSD
            (last-separator-csd (car csdl)))
      (declare (type simple-string control-string) (type fixnum index))
      (loop                     ; new directive altogether
        (tagbody
          (when (>= index (length control-string))
            (go string-ended))
          (setq ch (schar control-string index))
          (unless (eql ch #\~)
            ;; possibly transform part of string into a separate directive,
            (setq csdl (setf (cdr csdl) (list (setq newcsd (make-csd)))))
            (setf (csd-type     newcsd) 1)
            (setf (csd-cs-index newcsd) index)
            (setq index (position #\~ control-string :start index))
            (unless index
              (setf (csd-data newcsd) (setq index (length control-string)))
              (go string-ended))
            (setf (csd-data newcsd) index))
          (setq csdl (setf (cdr csdl) (list (setq newcsd (make-csd)))))
          (setf (csd-type         newcsd) 2)
          (setf (csd-cs-index     newcsd) index)
          (setf (csd-parm-list    newcsd) nil)
          (setf (csd-v-or-#-p     newcsd) nil)
          (setf (csd-colon-p      newcsd) nil)
          (setf (csd-atsign-p     newcsd) nil)
          (setf (csd-data         newcsd) nil)
          (setf (csd-clause-chain newcsd) nil)

          param                 ; parameter of a directive may begin
          (incf index)
          (when (>= index (length control-string))
            (format-error control-string index (errorstring))
            (go string-ended))
          (setq ch (schar control-string index))
          (when (digit-char-p ch) (go num-param))
          (case ch
            ((#\+ #\-) (go num-param))
            (#\' (go quote-param))
            ((#\V #\v #\#)
             (push (if (eql ch #\#) ':ARG-COUNT ':NEXT-ARG)
                   (csd-parm-list newcsd))
             (setf (csd-v-or-#-p newcsd) T)
             (go param-ok-1))
            (#\, (push nil (csd-parm-list newcsd)) (go param))
            (#\: (go colon-modifier))
            (#\@ (go atsign-modifier))
            (T (go directive)))

          num-param             ; numerical parameter
          (multiple-value-setq (intparam index)
            (parse-integer control-string :start index :junk-allowed t))
          (unless intparam
            (format-error control-string index
                          (TEXT "~A must introduce a number.")
                          ch))
          (push intparam (csd-parm-list newcsd))
          (go param-ok-2)

          quote-param           ; Quote-Parameter-Treatment
          (incf index)
          (when (>= index (length control-string))
            (format-error control-string index
              (TEXT "The control string terminates in the middle of a parameter."))
            (go string-ended))
          (setq ch (schar control-string index))
          (push ch (csd-parm-list newcsd))

          param-ok-1            ; Parameter OK
          (incf index)
          param-ok-2            ; Parameter OK
          (when (>= index (length control-string))
            (format-error control-string index (errorstring))
            (go string-ended))
          (setq ch (schar control-string index))
          (case ch
            (#\, (go param))
            (#\: (go colon-modifier))
            (#\@ (go atsign-modifier))
            (T (go directive)))

          colon-modifier        ; after :
	  (when (csd-colon-p newcsd)
	     (format-error control-string index
			   (TEXT "Too many colon modifiers supplied")))
          (setf (csd-colon-p newcsd) T)
          (go param)

          atsign-modifier       ; after @
	  (when (csd-colon-p newcsd)
	     (format-error control-string index
			   (TEXT "Too many at modifiers supplied")))
          (setf (csd-atsign-p newcsd) T)
          (go param)

          directive             ; directive (its Name) reached
          (setf (csd-parm-list newcsd) (nreverse (csd-parm-list newcsd)))
          (let ((directive-name
                  (cdr (assoc (char-upcase ch)
                           ; with function-definition     ; without function-definition
                         '((#\A . FORMAT-ASCII)
                           (#\S . FORMAT-S-EXPRESSION)
                           (#\W . FORMAT-WRITE)
                           (#\D . FORMAT-DECIMAL)
                           (#\B . FORMAT-BINARY)
                           (#\O . FORMAT-OCTAL)
                           (#\X . FORMAT-HEXADECIMAL)
                           (#\R . FORMAT-RADIX)
                           (#\P . FORMAT-PLURAL)
                           (#\C . FORMAT-CHARACTER)
                           (#\F . FORMAT-FIXED-FLOAT)
                           (#\E . FORMAT-EXPONENTIAL-FLOAT)
                           (#\G . FORMAT-GENERAL-FLOAT)
                           (#\$ . FORMAT-DOLLARS-FLOAT)
                           (#\% . FORMAT-TERPRI)
                           (#\_ . FORMAT-PPRINT-NEWLINE)
                           (#\I . FORMAT-PPRINT-INDENT)
                           (#\& . FORMAT-FRESH-LINE)      (#\Newline . #\Newline)
                           (#\| . FORMAT-PAGE)
                           (#\~ . FORMAT-TILDE)
                           (#\T . FORMAT-TABULATE)
                           (#\* . FORMAT-GOTO)
                           (#\? . FORMAT-INDIRECTION)
                           (#\/ . FORMAT-CALL-USER-FUNCTION)
                           (#\( . FORMAT-CASE-CONVERSION) (#\) . FORMAT-CASE-CONVERSION-END)
                           (#\[ . FORMAT-CONDITIONAL)     (#\] . FORMAT-CONDITIONAL-END)
                           (#\{ . FORMAT-ITERATION)       (#\} . FORMAT-ITERATION-END)
                           (#\< . FORMAT-JUSTIFICATION)   (#\> . FORMAT-JUSTIFICATION-END)
                           (#\^ . FORMAT-UP-AND-OUT)      (#\; . FORMAT-SEPARATOR)
                           (#\! . FORMAT-CALL))))))
            (if directive-name
              (setf (csd-data newcsd) directive-name)
              (format-error control-string index
                (TEXT "Non-existent format directive"))))
          (incf index)
          (case ch
            (#\/
             (let* ((start index)
                    (end (or (position #\/ control-string :start start)
                             (format-error control-string index
                               (TEXT "Closing '/' is missing"))))
                    (pos (position #\: control-string :start start :end end))
                    (name (string-upcase
                            (subseq control-string
                                    (if pos
                                      (if (char= #\: (char control-string (1+ pos))) (+ 2 pos) (1+ pos))
                                      start)
                                    end)))
                    (pack (if pos
                            (let ((packname
                                    (string-upcase
                                      (subseq control-string start pos))))
                              (or (find-package packname)
                                  (format-error control-string index
                                    (TEXT "There is no package with name ~S")
                                    packname)))
                            *common-lisp-user-package*)))
               (push (list (intern name pack)) (csd-parm-list newcsd))
               (setq index (1+ end))))
            (( #\( #\[ #\{)
             (multiple-value-setq (index csdl)
               (format-parse-cs control-string index csdl
                 (case ch (#\( #\)) (#\[ #\]) (#\{ #\}) ))))
            (#\<
             (multiple-value-setq (index csdl)
               (format-parse-cs control-string index csdl #\>))
             ;; (assert (eq (csd-data (car csdl)) 'FORMAT-JUSTIFICATION-END))
             (when (csd-colon-p (car csdl))
               (setf (csd-data newcsd) 'FORMAT-LOGICAL-BLOCK)))
            (( #\) #\] #\} #\> )
             (unless stop-at
               (format-error control-string index
                 (TEXT "The closing format directive '~A' does not have a corresponding opening one.")
                 ch))
             (unless (eql ch stop-at)
               (format-error control-string index
                 (TEXT "The closing format directive '~A' does not match the corresponding opening one. It should read '~A'.")
                 ch stop-at))
             (setf (csd-clause-chain last-separator-csd) csdl)
             (go end))
            (#\;
             (unless (or (eql stop-at #\]) (eql stop-at #\>))
               (format-error control-string index
                 (TEXT "The ~~; format directive is not allowed at this point.")))
             (setf (csd-clause-chain last-separator-csd) csdl)
             (setq last-separator-csd newcsd))
            (#\Newline
             (setf (csd-type newcsd) 0)
             (if (csd-colon-p newcsd)
               (if (csd-atsign-p newcsd)
                 (format-error control-string index
                   (TEXT "The ~~newline format directive cannot take both modifiers."))
                 nil) ; ~:<newline> -> ignore Newline, retain Whitespace
               (progn
                 (when (csd-atsign-p newcsd)
                   ;; ~@<newline> -> part of String with Newline for output
                   (setf (csd-type newcsd) 1)
                   (setf (csd-cs-index newcsd) (1- index))
                   (setf (csd-data newcsd) index))
                 (setq index
                   (or (position-if-not #'whitespacep control-string :start index)
                       (length control-string)))))))
        ) ; tagbody finished
      )   ; loop finished

      string-ended
      (when stop-at
        (format-error control-string index
          (TEXT "An opening format directive is never closed; expecting '~A'.")
          stop-at))

      end
      (return (values index csdl)))))

)

#.(setf (ext:package-lock :system) t)

(in-package :swank-backend)

;;; Inspecting

(defclass clisp-inspector (inspector)
  ())

(defimplementation make-default-inspector ()
  (make-instance 'clisp-inspector))

(defmethod inspect-for-emacs ((o t) (inspector clisp-inspector))
  (declare (ignore inspector))
  (let* ((*print-array* nil) (*print-pretty* t)
	 (*print-circle* t) (*print-escape* t)
	 (*print-lines* custom:*inspect-print-lines*)
	 (*print-level* custom:*inspect-print-level*)
	 (*print-length* custom:*inspect-print-length*)
	 (sys::*inspect-all* (make-array 10 :fill-pointer 0 :adjustable t))
	 (tmp-pack (make-package (gensym "INSPECT-TMP-PACKAGE-")))
	 (*package* tmp-pack)
	 (sys::*inspect-unbound-value* (intern "#<unbound>" tmp-pack)))
    (let ((inspection (sys::inspect-backend o)))
      (values (format nil "~S~% ~A~{~%~A~}" o 
		      (sys::insp-title inspection)
		      (sys::insp-blurb inspection))
              (loop with count = (sys::insp-num-slots inspection)
                    for i upto count
                   for (value name) = (multiple-value-list (funcall (sys::insp-nth-slot inspection) i))
                   collect `(:value ,name)
                   collect " = "
                   collect `(:value ,value)
                   collect '(:newline))))))

#-#.(cl:if swank-backend::*have-mop* '(cl:and) '(cl:or))
(progn
  (defmethod inspect-for-emacs ((o standard-object) (inspector clisp-inspector))
  (declare (ignore inspector))
  (values (format nil "An instance of the class" (class-of o))
          `("Sorry, inspecting of instances is not supported in this version of CLISP."
            (:newline)
            "Please upgrade to a recent version of CLISP.")))

  (defmethod inspect-for-emacs ((gf standard-generic-function) (inspector clisp-inspector))
    (declare (ignore inspector))
    (values "A generic function."
            `("Sorry, inspecting of generic functions is not supported in this version of CLISP."
              (:newline)
              "Please upgrade to a recent version of CLISP.")))

  (defmethod inspect-for-emacs ((method standard-method) (inspector t))
    (declare (ignore inspector))
    (values "A standard method."
            `("Sorry, inspecting of methods is not supported in this version of CLISP."
              (:newline)
              "Please upgrade to a recent version of CLISP.")))

  (defmethod inspect-for-emacs ((class standard-class) (inspector t))
    (declare (ignore inspector))
    (values "A class."
            `("Sorry, inspecting of classes is not supported in this version of CLISP."
              (:newline)
              "Please upgrade to a recent version of CLISP.")))

  (defmethod inspect-for-emacs ((slot swank-mop:standard-slot-definition) (inspector t))
    (declare (ignore inspector))))

(defimplementation quit-lisp ()
  #+lisp=cl (ext:quit)
  #-lisp=cl (lisp:quit))

;;; Local Variables:
;;; eval: (put 'compile-file-frobbing-notes 'lisp-indent-function 1)
;;; eval: (put 'dynamic-flet 'common-lisp-indent-function 1)
;;; End:
