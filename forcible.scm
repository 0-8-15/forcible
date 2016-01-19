(use srfi-18)

(declare
 (disable-interrupts) ;; alternative: use `hopefully` for the 'forcible' record

 (no-bound-checks)
 (no-procedure-checks)
 (local)
 (inline)
 (safe-globals)
 (specialize)
 (strict-types)

 )

(module
 forcible
 (
  eager
  (lazy make-lazy-promise)
  (delay make-delayed-promise)
  timeout-condition?
  (delay/timeout make-delayed-promise make-delayed-promise/timeout-ex make-delayed-promise/timeout)
  (future make-future-promise)
  (future/timeout make-future-promise/timeout)
  (lazy-future make-lazy-future-promise)
  demand
  force
  fulfil!
  expectable
  )
 (import (except scheme force delay))
 (import (except chicken make-promise promise?))
 (import srfi-18)

(define-record forcible-timeout)

(define %forcible-timeout (make-forcible-timeout))

(define (timeout-condition? x) (eq? x %forcible-timeout))

(define-type :promise: (struct forcible))
(: promise-box (:promise: -> pair))
(: promise-box-set! (:promise: pair -> *))
(: promise? (* --> boolean : :promise:))
(define-record-type forcible
  (make-promise box)
  promise?
  (box promise-box promise-box-set!))

(: eager (&rest -> :promise:))
(define (eager . vals)
  (make-promise (cons 'eager vals)))

(define (make-lazy-promise thunk)
  (make-promise (cons (make-mutex) thunk)))

(define-syntax lazy
  (syntax-rules ()
    ((_ exp) (make-lazy-promise (lambda () exp)))))

(define (make-delayed-promise thunk)
  (lazy (call-with-values thunk eager)))

(define-syntax delay
  (syntax-rules ()
    ((_ exp) (make-delayed-promise (lambda () exp)))))

#;(define (make-future-promise thunk)
  (let ((thread (make-thread thunk 'future)))
    (thread-start! thread)
    (make-promise (cons thread thunk))))

(define (make-future-promise thunk)
  (let* ((p (cons #f thunk))
	 (promise (make-promise p))
	 (thread (make-thread
		  (lambda ()
		    (handle-exceptions
		     ex (fulfil! promise #f ex)
		     (receive
		      results (thunk)
		      (fulfil!* promise #t results))))
		  'future)))
    (set-car! p thread)
    (thread-start! thread)
    promise))

(define-syntax future
  (syntax-rules ()
    ((_ exp) (make-future-promise (lambda () exp)))))

(define (make-future-promise/timeout thunk timeout)
  (let* ((promise (make-promise (cons #f thunk)))
	 (thread (make-thread
		  (lambda ()
		    (handle-exceptions
		     ex (fulfil! promise #f ex)
		     (let ((to (thread-start!
				(let ((thread (current-thread)))
				  (lambda ()
				    (thread-sleep! timeout)
				    (let ((state (thread-state thread)))
				      (case state
					((dead terminated))
					(else (thread-signal! thread %forcible-timeout)))))))))
		       (receive
			results (thunk)
			(thread-terminate! to)
			(fulfil!* promise #t results)))))
		  'future)))
    (set-car! (promise-box promise) thread)
    (thread-start! thread)
    promise))

(define-syntax future/timeout
  (syntax-rules ()
    ((_ to exp) (make-future-promise/timeout (lambda () exp) to))))

(define (make-lazy-future-promise thunk)
  (let ((thread (make-thread thunk 'future)))
    (make-promise (cons thread thunk))))

(define-syntax lazy-future
  (syntax-rules ()
    ((_ exp) (make-lazy-future-promise (lambda () exp)))))

(: demand (:promise: -> boolean))
(define (demand promise)
  (let ((key (car (promise-box promise))))
    (if (and (thread? key) (eq? (thread-state key) 'created))
	(begin
	  (thread-start! key)
	  #t)
	#f)))

(define-inline (register-promise-timeout! promise timeout thunk)
  (mutex-specific-set!
   (car (promise-box promise))
   (make-thread
    (lambda ()
      (thread-sleep! timeout)
      (handle-exceptions
       ex (fulfil! promise #f ex)
       (receive results (thunk) (fulfil!* promise #t results)))))))

(define-inline (register-promise-timeout/safe! promise timeout thunk)
  (mutex-specific-set!
   (car (promise-box promise))
   (make-thread
    (lambda ()
      (thread-sleep! timeout)
      (thunk)))))

(define-inline (start-promise-timeout! key)
  (let ((t (mutex-specific key)))
    (if (thread? t) (thread-start! t))))

(define-inline (cancel-promise-timeout! key)
  (let ((timeout (mutex-specific key)))
    (if (thread? timeout) (thread-terminate! timeout))))

(define-inline (cancel-future-timeout! key)
  (let ((timeout (thread-specific key)))
    (if (thread? timeout)
	(begin
	  (thread-terminate! timeout)
	  (thread-specific-set! key #f)))))

(define-inline (lock-promise-mutex! key)
  (start-promise-timeout! key)
  (mutex-lock! key))

(define-inline (unlock-promise-mutex! key)
  (mutex-unlock! key)
  (cancel-promise-timeout! key))

(: fulfil!* (:promise: boolean list -> boolean))
(define (fulfil!* promise type args)
  (let* ((content (promise-box promise))
	 (key (car content)))
    (if (symbol? key) #f
	(begin
	  (set-cdr! content args)
	  (set-car! content (if type 'eager 'failed))
	  (cond
	   ((mutex? key) (unlock-promise-mutex! key))
	   ;; TBD: handle futures too.
	   )
	  #t))))

(: fulfil! (:promise: boolean &rest -> boolean))
(define (fulfil! promise type . args) (fulfil!* promise type args))

(: expectable (or (&rest * (procedure (*) . *) -> (procedure (true &rest) boolean) :promise:)
		  (&rest * (procedure (*) . *) -> (procedure (false *) boolean) :promise:)))
(define (expectable . name+thunk)
  (let* ((thunk (and (pair? name+thunk) (pair? (cdr name+thunk)) (cadr name+thunk)))
	 (mux (or thunk (make-mutex (if (pair? name+thunk) (car name+thunk) 'expectation))))
	 (promise (if thunk
		      (make-delayed-promise thunk)
		      (make-promise (list mux)))))
    (or thunk (mutex-lock! mux #f #f))
    (values
     (lambda (kind . args) (fulfil!* promise kind args))
     promise)))

;; TBD: The timeout handling is rather stupid now.  Better one to
;; come.
(define (make-delayed-promise/timeout thunk timeout on-timeout);; WRONG
  (let ((promise (make-delayed-promise thunk)))
    (register-promise-timeout! promise timeout on-timeout)
    promise))

(define (make-delayed-promise/timeout-ex thunk timeout)
  (let ((promise (make-delayed-promise thunk)))
    (register-promise-timeout/safe!
     promise
     timeout
     (lambda ()
       (and-let* ((key (car (promise-box promise)))
		  (owner (mutex-state key))
		  ((thread? owner)))
		 (thread-signal! owner %forcible-timeout))))
    promise))

(define-syntax delay/timeout
  (syntax-rules ()
    ((_ exp) (make-delayed-promise (lambda () exp)))
    ((_ to exp) (make-delayed-promise/timeout-ex (lambda () exp) to))
    #;((_ to exp then)
     (make-delayed-promise/timeout (lambda () exp) to (lambda () then)))))

(: force1! (:promise: -> :promise:))
(define (force1! promise)
  (let* ((content (promise-box promise))
	 (key (car content)))
    (cond
     ((symbol? key) promise)
     ((mutex? key)
      (if (eq? (mutex-state key) (current-thread))
	  (let* ((promise* ((cdr content)))        
		 (content  (promise-box promise))) ; * 
	    (if (not (eq? (car content) 'eager))   ; *
		(let ((content* (promise-box promise*)))
		  (set-car! content (car content*))
		  (set-cdr! content (cdr content*))
		  (promise-box-set! promise* content)))
	    (unlock-promise-mutex! key)
	    (force1! promise))
	  (begin
	    (lock-promise-mutex! key)
	    (force1! promise))))
     ((thread? key)
      (if (eq? (thread-state key) 'created) (thread-start! key))
      (receive
       vals (thread-join! key)
       (let ((content (promise-box promise)))
	 (if (not (symbol? (car content)))
	     (begin
	       (set-car! content 'eager)
	       (set-cdr! content vals))))
       (force1! promise)))
     (else (error "forcible: unknown promise kind" key)))))

(: force (* &optional (or (procedure (*) . *) false) -> . *))
(define (force obj . fail)
  (if (promise? obj)
      (let* ((fh (and (pair? fail) (car fail)))
	     (result
	      (cond
	       ;; Result already available.
	       ((symbol? (car (promise-box obj))) obj)
	       ;; Backward compatible case does not cache exceptions.
	       ((and (pair? fail) (not fh)) (force1! obj))
	       (else (handle-exceptions
		      ex
		      (let ((ex (if (uncaught-exception? ex)
				    (uncaught-exception-reason ex)
				    ex)))
			(promise-box-set! obj (list 'failed ex))
			obj)
		      (force1! obj)))))
	     (content (promise-box result)))
	(if (eq? (car content) 'eager)
	    (apply values (cdr content))
	    (let ((ex (cadr content)))
	      (if (procedure? fh) (fh ex) (raise ex)))))
      obj))

)
