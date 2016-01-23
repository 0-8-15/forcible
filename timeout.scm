(import (prefix pigeon-hole q:))

(define %timeout-period 1)

(define (timeout-period . arg)
  (if (pair? arg)
      (let ((old %timeout-period)
	    (new (car arg)))
	(if (number? new)
	    (begin
	      (set! %timeout-period new)
	      old)
	    (error "illegal timeout period" new)))
      %timeout-period))

(define-constant ms/s 1000.0)
(define-constant tmo-epsilon 0.1)

(define-inline (intern-timeout-time x) x)

(define-inline (tmo-current-time) (/ (current-milliseconds) ms/s))

(define-inline (make-timeout-treetype)
  (make-llrb-treetype
   #f ;; KEY?
   (lambda (k p) (< (abs (- k p)) tmo-epsilon)) ;; EQUAL
   (lambda (k p) (< k p)) ;; LESS
   ))

(define long-running (make-table (make-timeout-treetype)))

(define-inline (execute-timeout-job! job)
  ;; (format (current-error-port) "Timeout job ~a\n" job)
  (cond
   ((thread? job)
    (let ((state (thread-state job)))
      (case state
	((dead terminated))
	(else (thread-signal! job %forcible-timeout)))))
   ((q:isa? job) (q:send/anyway! job %forcible-timeout))
   ;; BEWARE: job must be sure to never run into an exception!
   ((procedure? job) (job))))

(define make-timeout-entry cons)

(define (timeout-entry? x) (and (pair? x) (cdr x)))

(define (timeout-entry-delay x) (car x))
(define (timeout-entry-job x) (cdr x))

(define (cancel-timeout-message! x) (if (timeout-entry? x) (set-cdr! x #f)))

(define current-timeout-queue (q:make 'timeout-queue capacity: 10))

(define (start-timeout-entry! entry)
  (and (timeout-entry? entry) (q:send/anyway! current-timeout-queue entry)))

(define (register-timeout-message! timeout object)
  (let ((entry (make-timeout-entry timeout object)))
    (q:send/anyway! current-timeout-queue entry)
    entry))

(define-inline (handle-timeout-entry! last now entry)
  (and-let*
   ((job (timeout-entry-job entry))
    (delta (timeout-entry-delay entry)))
   (let ((due (intern-timeout-time (+ last delta))))
     ;;(format (current-error-port) "Timeout job ~a last ~a now ~a due ~a delta ~a\n" job last now due delta)
     (if (> due now)
	 (table-update! long-running due (lambda (x) (cons entry x)) (lambda () '()))
	 (execute-timeout-job! job)))))

(define (timeout-handler)
  (let again ((last (intern-timeout-time (tmo-current-time)))
	      (last-entries '()))
    ;;(format (current-error-port) "Timeout handler\n")
    (thread-sleep! %timeout-period)
    (let ((now (intern-timeout-time (tmo-current-time))))
      (for-each
       (lambda (e) (handle-timeout-entry! last now e))
       last-entries)
      (let loop ()
	(receive
	 (due entries) (table-min long-running (lambda () (values #f #f)))
	 (if (and due (< due now))
	     (begin
	       (table-delete! long-running due)
	       (for-each
		(lambda (e) (and-let* ((job (timeout-entry-job e))) (execute-timeout-job! job)))
		entries)
	       (loop)))))
      (again now (q:receive-all! current-timeout-queue)))))

(thread-start! timeout-handler)
