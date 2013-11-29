(in-package #:simple-utils)

;;; -----------------------------------------------------------------------------------------
;;; context & thrading
;;; -----------------------------------------------------------------------------------------
 
#+ccl
(defmacro call-in-main-thread ((&key (waitp t)) &body body)
  "Some routine must call in main thread. especially about sounds or gui works.
 This macro interruption to main-thread, and wait until returning body form."
  (if waitp `(ccl::call-in-initial-process
	      (lambda () ,@body))
      `(ccl::process-interrupt
	ccl::*initial-process*
	(lambda () ,@body))))

#+sbcl
(defmacro call-in-main-thread ((&key (waitp t)) &body body)
  "Some routine must call in main thread. especially about sounds or gui works.
 This macro interruption to main-thread, and wait until returning body form."
  (let ((semaphore (gensym))
	(result (gensym)))
    `(let ((,semaphore (when ,waitp
			 (sb-thread:make-semaphore)))
	   (,result nil))
       (sb-thread:interrupt-thread
	(sb-thread:main-thread)
	(lambda ()
	  (unwind-protect
	       (handler-case (setf ,result (progn ,@body))
		 (error () (format t "~&error with call-in-main-thread~%")))
	    (when ,waitp
	      (sb-thread:signal-semaphore ,semaphore)))))
       (when ,waitp
	 (sb-thread:wait-on-semaphore ,semaphore)
 	 ,result))))

(defmacro -> (&optional arg &body body)
  "(-> (+ 1 2) (* 3) (/ 3))  expand to => (/ (* (+ 1 2) 3) 3)"
  (when arg
    (if (not body) arg
	(let* ((form (mklist (car body)))
	       (form (append (list (car form) arg) (cdr form))))
	  (reduce (lambda (x y)
		    (let ((y (mklist y)))
		      (append (list (car y) x) (cdr y)))) (append (list form) (cdr body)))))))

;;; -----------------------------------------------------------------------------------------
;;; package
;;; -----------------------------------------------------------------------------------------

(defun rename-package-nicknames (package &rest nicknames)
  "for Alias short package name from too long package name."
  (let ((pkg (package-name (find-package package))))
    #+ccl(ccl::rename-package pkg pkg (append nicknames (package-nicknames pkg)))
    #+sbcl
    (let ((lock-p (sb-ext:package-locked-p pkg)))
      (when lock-p (sb-ext:unlock-package pkg))
      (prog1
	  (rename-package pkg pkg (append nicknames (package-nicknames pkg)))
	(when lock-p (sb-ext:lock-package pkg))))))

;;; -----------------------------------------------------------------------------------------
;;; file
;;; -----------------------------------------------------------------------------------------
(defun get-fullpath (path)
  "returning absoulte full-pathname of path"
  #+ccl (namestring (ccl:full-pathname path))
  #+sbcl (full-pathname path))

#+sbcl
(defun full-pathname (dir)
  (labels ((absolute-dir (dir)
	     (if (eql (car dir) :absolute) (if (find :home dir)
					       (append
						(pathname-directory (user-homedir-pathname))
						(cdr (member :home dir)))
					       dir)
		 (let* ((default-dir
			  (pathname-directory *default-pathname-defaults*)))
		   (when (find :up dir)
		     (setf dir (cdr dir))
		     (setf default-dir (butlast default-dir)))
		   (append default-dir (cdr dir))))))
    (namestring (make-pathname :directory (absolute-dir (pathname-directory dir)) :name (pathname-name dir) :type (pathname-type dir)))))


;;; -----------------------------------------------------------------------------------------
;;; printing
;;; -----------------------------------------------------------------------------------------
(defun println (thing &rest things)
  (format t "~&~{~a ~}~%" (cons thing things)))

;;; -----------------------------------------------------------------------------------------
;;; sequence
;;; -----------------------------------------------------------------------------------------

(defun mklist (val)
  "If val is lisp, then return. but if val is atom, make list from val."
  (if (listp val) val (list val)))

(defun partition (lst x)
  (labels ((partition-helper (lst acc x)
	     (cond ((not lst) acc)
		   ((< (length lst) x) (cons lst acc))
		   (t (partition-helper (subseq lst x) (cons (subseq lst 0 x) acc) x))))) 
    (reverse (partition-helper lst '() x))))

(defmethod cat ((sequence string) &rest sequences)
  (apply #'concatenate 'string sequence sequences))

(defmethod cat ((sequence list) &rest sequences)
  (apply #'append sequence sequences))


(defun dup (object &optional (n 2))
  (duplicate object n))

(defmethod duplicate (self (n fixnum))
  (if (not (listp self)) (make-list n :initial-element self)
      (loop for i from 0 below n
	 collect (copy-list self))))

(defmethod duplicate ((self function) (n fixnum))
  (loop for i from 0 below n collect (funcall self i)))

(defmethod duplicate ((self function) (n list))
  (loop for i in n collect (funcall self i)))


(defmacro do-while ((var form) &body body)
  `(do ((,var ,form ,form))
       ((not ,var))
     ,@body))


;;; -----------------------------------------------------------------------------------------
;;; read macro
;;; -----------------------------------------------------------------------------------------

;;; #! read-macro - clojure style of lambda functions.

(defvar *name-db*)
(defmethod name-parse ((symbol symbol))
  (let ((name-string (string-upcase symbol)))
    (if (char= #\% (elt name-string 0))
	(let ((number (progn (when (= 1 (length name-string))
			       (setq name-string (format nil "~a1" name-string)))
			     (parse-integer (subseq name-string 1)))))
	  (when (zerop number) (error "in-args number must not 0"))
	  (let ((sym (assoc number *name-db*)))
	    (if sym (cdr sym)
		(let ((new-symb (cons number (gensym))))
		  (setf *name-db* (append *name-db* (list new-symb)))
		  (cdr new-symb)))))
	symbol)))

(defmethod name-parse ((self t))
  self)

(defun do-parse-from-form (form)
  (cond ((null form) nil)
	((atom form) (name-parse form))
	(t (cons (do-parse-from-form (car form))
		 (do-parse-from-form (cdr form))))))

(defun fill-in-name-db (db)
  (when db
    (let ((max-number (reduce  #'max db :key #'car)))
      (loop for i from 1 to max-number
	 collect (let ((val (find i db :key #'car)))
		   (if val val (cons i (gensym))))))))

(set-dispatch-macro-character #\# #\!
		     (lambda (stream char1 char2)
		       (declare (ignore char1 char2))
		       (let ((first-char (read-char stream nil nil)))
			 (if (char= first-char #\space) (error "bad syntax..by #\\space")
			     (unread-char first-char stream)))
		       (let ((*name-db* nil))
			 (let ((body-form (do-parse-from-form (read stream nil nil))))
			   `(lambda ,(cat (mapcar #'cdr (fill-in-name-db *name-db*)) '(&rest rest))
			      (declare (ignorable rest))
			      ,body-form)))))





