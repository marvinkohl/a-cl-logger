;; -*- lisp -*-

(in-package :a-cl-logger)
(cl-interpol:enable-interpol-syntax)

(defgeneric append-message (category log-appender message level)
  (:documentation
   "The method responsible for actually putting the logged information somewhere")
  (:method :around (category log-appender message level)
    (handler-bind
        ((error (lambda (c)  
                  (if *debugger-hook*
                      (invoke-debugger c)
                      (format *error-output* "ERROR Appending Message: ~A" c))
                  (return-from append-message))))
      (call-next-method))))

(defgeneric %print-message (log appender message stream)
  (:method (log appender message stream)
    (etypecase message
      (message
          (if (format-control message)
              (apply #'format stream (format-control message) (args message))
              (format stream "~{~A:~A~^, ~}" (args-plist message))))
      (function (%print-message log appender (funcall message) stream))
      (string (write-sequence message stream))
      (list (if (stringp (first message))
                (apply #'format stream message)
                (apply #'format stream "~{~A ~}" message))))))

(defclass appender ()
  ()
  (:documentation "The base of all log appenders (destinations)"))

(defclass stream-log-appender (appender)
  ((stream :initarg :stream :accessor log-stream)
   (date-format :initarg :date-format :initform :time
    :documentation "Format to print dates. Format can be one of: (:iso :stamp :time)"))
  (:documentation "Human readable to the console logger."))

(defmacro with-stream-restarts ((s recall) &body body)
  `(restart-case
    (progn ,@body)
    (use-*debug-io* ()
     :report "Use the current value of *debug-io*"
     (setf (log-stream ,s) *debug-io*)
     ,recall)
    (use-*standard-output* ()
     :report "Use the current value of *standard-output*"
     (setf (log-stream ,s) *standard-output*)
     ,recall)
    (silence-logger ()
     :report "Ignore all future messages to this logger."
     (setf (log-stream ,s) (make-broadcast-stream)))))

(defmethod append-message ((category log-category)
                           (s stream-log-appender)
                           message level)
  (with-stream-restarts (s (append-message category s message level))
    (maybe-with-presentations ((log-stream s) str)
      (let* ((category-name (symbol-name (name category)))
             (level-name (typecase level
                           (symbol level)
                           (integer (log-level-name-of level)))))
        (multiple-value-bind (second minute hour day month year)
            (decode-universal-time (get-universal-time))
          (ecase (slot-value s 'date-format)
            (:iso (format str "~d-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D"
                          year month day hour minute second))
            (:stamp (format str "~d~2,'0D~2,'0D ~2,'0D~2,'0D~2,'0D"
                            year month day hour minute second))
            (:time (format str "~2,'0D:~2,'0D:~2,'0D"
                           hour minute second))))
        (princ #\space str)
        (format str "~A/~7A "
                (%category-name-for-output category-name)
                level-name)
        (%print-message category s message str)
        (terpri str)
        ))))

(defun logger-inspector-lookup-hook (form)
  (when (symbolp form)
    (let ((logger (or (ignore-errors (get-logger form))
                      (ignore-errors (get-logger (logger-name-from-helper form))))))
      (when logger
        (values logger t)))))

(defclass file-log-appender (stream-log-appender)
  ((log-file :initarg :log-file :accessor log-file
             :documentation "Name of the file to write log messages to.")
   (buffer-p :initarg :buffer-p :accessor buffer-p :initform t))
  (:default-initargs :date-format :iso))

(defun %open-log-file (ufla)
  (setf (log-stream ufla)
        (ignore-errors
          (let ((f (open (log-file ufla) :if-exists :append :if-does-not-exist :create
                         :direction :output
                         :external-format :utf-8)))
            (push (lambda () (force-output f) (close f)) sb-ext::*exit-hooks*)
            f))))

(defmethod (setf log-file) :after (val (ufla file-log-appender))
  (%open-log-file ufla))

(defmethod append-message ((category log-category)
                           (appender file-log-appender)
                           message level)
  (unless (and (slot-boundp appender 'stream)
               (log-stream appender))
    (%open-log-file appender))

  (restart-case (handler-case
                    (progn (call-next-method)
                           (unless (buffer-p appender)
                             (force-output (log-stream appender))))
                  (error () (invoke-restart 'open-log-file)))
    (open-log-file ()
      (%open-log-file appender)
      (ignore-errors (call-next-method)))))
