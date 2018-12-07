
(cond-expand
 (chicken-4 (require-library srfi-18 pigeon-hole pigeonry simple-timer lolevel))
 (else ))

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
 (promise?
  eager
  (lazy make-lazy-promise)
  (lazy/timeout make-lazy-promise make-lazy-promise/timeout)
  (delay make-delayed-promise)
  timeout-condition?
  (delay/timeout make-delayed-promise make-delayed-promise/timeout-ex)
  (future make-future-promise)
  (future/timeout make-future-promise/timeout)
  (&begin make-future-promise)
  (&begin/timeout make-future-promise/timeout)
  (lazy-future make-lazy-future-promise)
  (order make-order-promise)
  (order/timeout make-order-promise)
  demand
  force
  fulfil!
  expectable
  )
 (import (except scheme force delay))
 (cond-expand
  (chicken-4
   (import (except chicken make-promise promise? with-exception-handler)))
  (else
   (import
    (chicken type)
    (except (chicken base) make-promise promise?)
    srfi-12
    (chicken time))))
 (import srfi-18)
 (import (prefix pigeonry threadpool-))
 (import simple-timer)

(define %catch-values list)
(define-inline (%apply-to-intercepted f i) (apply f i))

(define timeout-condition? timer-condition?) ; obsolete but affects documented API
(define register-timeout-message! register-timer-task!)
(define cancel-timeout-message! cancel-timer-task!)

(define-type :promise: (struct forcible))
(: promise-box (:promise: -> pair))
(: promise-box-set! (:promise: pair -> *))
(: promise? (* --> boolean : :promise:))
(define-record-type forcible
  (make-promise box)
  promise?
  (box promise-box promise-box-set!))

(: eager (&rest -> :promise:))
(cond-expand
 (overwrite-dynamic-wind
  (define (eager . vals)
    (make-promise (cons 'eager (list->vector vals)))))
 (else
  (define (eager . vals)
    (make-promise (cons 'eager vals)))))

#;(define (make-lazy-promise thunk)
  (make-promise (cons (make-mutex) thunk)))

(define (make-lazy-promise thunk)
  (make-promise
   (cons
    (make-mutex)
    (lambda ()
      (let ((p (thunk)))
	(if (promise? p) p
	    (error "missuse of lazy" p)))))))

(define-syntax lazy
  (syntax-rules ()
    ((_ exp) (make-lazy-promise (lambda () exp)))))

#;(define (make-delayed-promise thunk)
  (lazy (call-with-values thunk eager)))

;; Manually inlined for speed.
(define (make-delayed-promise thunk)
  (make-promise
   (cons (make-mutex 'delayed)
	 (lambda ()
	   (make-promise (cons 'eager (call-with-values thunk %catch-values)))))))

(define-syntax delay
  (syntax-rules ()
    ((_ exp) (make-delayed-promise (lambda () exp)))))

#;(define (make-future-promise thunk)
  (let ((thread (make-thread thunk 'future)))
    (thread-start! thread)
    (make-promise (cons thread thunk))))


(define (make-future-promise* thunk started)
  (let* ((p (cons #f thunk))
	 (promise (make-promise p))
	 (thread (make-thread
		  (lambda ()
		    (handle-exceptions
		     ex (fulfil! promise #f ex)
		     (fulfil!* promise #t (call-with-values thunk %catch-values))))
		  'future)))
    (set-car! p thread)
    (if started (thread-start! thread))
    promise))

(define (make-future-promise thunk) (make-future-promise* thunk #t))

(define-syntax future
  (syntax-rules ()
    ((_ exp) (make-future-promise (lambda () exp)))))

(define-syntax &begin
  (syntax-rules ()
    ((_ body ...) (make-future-promise (lambda () body ...)))))

(define (make-future-promise/timeout thunk timeout)
  (let* ((p (cons #f thunk))
	 (promise (make-promise p))
	 (thread (make-thread
		  (lambda ()
		    (handle-exceptions
		     ex (fulfil! promise #f ex)
		     (let ((to (register-timeout-message! timeout (current-thread))))
		       (let ((results (call-with-values thunk %catch-values)))
			 (cancel-timeout-message! to)
			 (fulfil!* promise #t results)))))
		  'future)))
    (set-car! p thread)
    (thread-start! thread)
    promise))

(define-syntax future/timeout
  (syntax-rules ()
    ((_ to exp) (make-future-promise/timeout (lambda () exp) to))))

(define-syntax &begin/timeout
  (syntax-rules ()
    ((_ to body ...) (make-future-promise/timeout (lambda () body ...) to))))

(define (make-lazy-future-promise thunk) (make-future-promise* thunk #f))

(define-syntax lazy-future
  (syntax-rules ()
    ((_ exp) (make-lazy-future-promise (lambda () exp)))))

(: demand (:promise: -> boolean))
(define (demand promise)
  (if (not (promise? promise)) (error "demand: not a promise" promise))
  (let ((key (car (promise-box promise))))
    (if (and (thread? key) (eq? (thread-state key) 'created))
	(begin
	  (thread-start! key)
	  #t)
	#f)))

(define-inline (unlock-promise-mutex! key)
  #;(cancel-promise-timeout! key)
  #;(assert (eq? (mutex-state (dbg (current-thread) key)) (current-thread)))
  (mutex-unlock! key))

(define-inline (unlock-other-promise-mutex! key)
  #;(cancel-promise-timeout! key)
  (mutex-unlock! key))

(: fulfil!* (:promise: boolean * -> boolean))
(define (fulfil!* promise type args)
  (let* ((content (promise-box promise))
	 (key (car content)))
    (if (symbol? key) #f
	(begin
	  (cond
	   ((and #;type (pair? args) (promise? (car args)))
	    (let* ((p* (car args)) (nc (promise-box p*)))
	      (set-cdr! content (cdr nc))
	      (set-car! content (car nc))
	      (promise-box-set! p* content)))
	   ((and #;type (vector? args) (eq? (vector-length args) 1) (promise? (vector-ref args 0)))
	    #;(display "Forcible has seen the interesting case\n" (current-error-port))
	    (let* ((p* (vector-ref args 0)) (nc (promise-box p*)))
	      (set-cdr! content (cdr nc))
	      (set-car! content (car nc))
	      (promise-box-set! p* content)))
	   (else
	    (set-cdr! content args)
	    (set-car! content (if type 'eager 'failed))))
	  (cond
	   ((mutex? key) (unlock-other-promise-mutex! key))
	   ;; TBD: handle futures too.
	   )
	  #t))))

(: fulfil! (:promise: boolean &rest -> boolean))
(define (fulfil! promise type . args) (fulfil!* promise type args))

(: expectable (or (&rest * (procedure (*) . *) -> (procedure (true &rest) boolean) :promise:)
		  (&rest * (procedure (*) . *) -> (procedure (false *) boolean) :promise:)))
(define (expectable . name+thunk)
  (let* ((thunk (and (pair? name+thunk) (pair? (cdr name+thunk)) (cadr name+thunk)))
	 (mux (or thunk (make-mutex 'service)))
	 (promise (if (procedure? thunk)
		      (make-delayed-promise thunk)
		      (make-promise (list mux)))))
    (if (not thunk)
	(mutex-lock! mux #f #f))
    (values
     (lambda (kind . args) (fulfil!* promise kind (cond-expand
						   (overwrite-dynamic-wind (list->vector args))
						   (else args))))
     promise)))

(define make-order-promise
  (let ()
    (define pool-type
      (threadpool-make-type
       (lambda (promise ex) (fulfil! promise #f ex))
       #f #;(lambda (root) #f)))
    ;;(define (pileup promise thunk) (receive args (thunk) (fulfil!* promise #t args)))
    (define (pileup promise) (fulfil!* promise #t (call-with-values (cadr (promise-box promise)) %catch-values)))
    (define (pileup/timeout promise timeout)
      (let ((to (register-timeout-message! timeout ##sys#current-thread)))
	(let ((args (call-with-values (cadr (promise-box promise)) %catch-values)))
	  (cancel-timeout-message! to)
	  (fulfil!* promise #t args))))
    ;; Pool is currently NOT REALLY limited.
    (define pile (threadpool-make 'pile #t pool-type))
    (define (sent-to-threadpool thunk timeout)
      (let* ((mux (make-mutex 'service)) ;; Beware name triggers "no exception handler".
	     (p (cons thunk '()))
	     (content (cons mux p))
	     (promise (make-promise content)))
	(if timeout
	    (threadpool-order! pile promise pileup/timeout (cons timeout '()))
	    (threadpool-order! pile promise pileup '()))
	(mutex-lock! mux #f #f)
	promise))
    sent-to-threadpool))

(define-syntax order
  (syntax-rules ()
    ((_ exp) (make-order-promise (lambda () exp) #f))))

(define-syntax order/timeout
  (syntax-rules ()
    ((_ exp) (make-order-promise (lambda () exp) #f))
    ((_ to exp) (make-order-promise (lambda () exp) to))))

(define (make-lazy-promise/timeout thunk timeout)
  (make-promise
   (let ((mux (make-mutex 'lazy/timeout)))
     (cons
      mux
      (lambda ()
	(let* ((to (register-timeout-message! timeout ##sys#current-thread))
	       (result (begin
			 ((mutex-specific mux) #f to)
			 ;;(call-with-values thunk %catch-values)
			 (thunk))))
	  (cancel-timeout-message! to)
	  ;;(%apply-to-intercepted values result)
	  (if (promise? result) result
	      (error "missuse of lazy/timeout" result))))))))

(define-syntax lazy/timeout
  (syntax-rules ()
    ((_ exp) (make-lazy-promise (lambda () exp)))
    ((_ to exp) (make-lazy-promise/timeout (lambda () exp) to))))

(define (make-delayed-promise/timeout-ex thunk timeout)
  (make-promise
   (let ((mux (make-mutex 'delayed/timeout)))
     (cons
      mux
      (lambda ()
	(let* ((to (register-timeout-message! timeout ##sys#current-thread))
	       (result (begin
			 ((mutex-specific mux) #f to)
			 (call-with-values thunk %catch-values))))
	  (cancel-timeout-message! to)
	  (make-promise (cons 'eager result))))))))

(define-syntax delay/timeout
  (syntax-rules ()
    ((_ exp) (make-delayed-promise (lambda () exp)))
    ((_ to exp) (make-delayed-promise/timeout-ex (lambda () exp) to))))

(: force1! (:promise: (or false (procedure (* *) undefined)) -> :promise:))
(define (force1! promise top)
  (let loop ((promise promise))
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
		    (promise-box-set! promise* content)
		    (unlock-promise-mutex! key)))
	      (loop promise))
	    (begin
	      (mutex-lock! key)
	      ;; Already done.  Don't abandon the mutex.  Avoid memory leak.
	      (if (symbol? (car (promise-box promise)))
		  (mutex-unlock! key)
		  (begin
		    (mutex-specific-set! key top)
		    (top (promise-box promise) #f)))
	      (loop promise))))
       ((thread? key)
	(if (eq? (thread-state key) 'created) (thread-start! key))
	(thread-join! key)
	promise)
       (else (error "forcible: unknown promise kind" key))))))

(: force (* &optional (or (procedure (*) . *) false) procedure -> . *))
(define (force obj #!optional (fh raise) (success values))
  (if (promise? obj)
      (let* (#;(fh (and (pair? fail) (car fail)))
	     (key (car (promise-box obj)))
	     (result
	      (cond
	       ;; Result already available.
	       ((symbol? key) obj)
	       ;; As CHICKEN makes it hard to not catch exceptions in
	       ;; threads we don't to so anymore.  Hence no exceptions here:
	       ((thread? key) (force1! obj #f))
	       ;; Backward compatible case does not cache exceptions.
	       #;((and (pair? fail) (not fh))
		(force1! obj (and (mutex? key) (mutex-specific key))))
	       (else
		(if (eq? (mutex-state key) (current-thread))
		    (force1! obj (mutex-specific key))
		    (begin
		      (mutex-lock! key)
		      (if (or (symbol? (car (promise-box obj)))
			      (eq? (mutex-name key) 'service))
			  ;; Already done.  Don't abandon the mutex.  Avoid memory leak.
			  (begin
			    (mutex-unlock! key)
			    obj)
			  (let ((last (promise-box obj))
				;; avoid 'tmo' to be optimized away
				(tmo (the (or false pair) #f)))
			    (handle-exceptions
			     ex
			     (let ((result (list 'failed ex)))
			       (if tmo (cancel-timeout-message! tmo))
			       (promise-box-set! obj result)
			       (if (not (eq? last (promise-box obj)))
				   (let ((lastkey (car last)))
				     (when
				      (not (eq? lastkey key))
				      (set-cdr! last result)
				      (set-car! last 'failed)
				      (if (mutex? lastkey) (mutex-unlock! lastkey)))))
			       (unlock-promise-mutex! key)
			       obj)
			     (let ((top (lambda (p t)
					  (if p (set! last p))
					  (if t (set! tmo t)))))
			       (mutex-specific-set! key top)
			       (force1! obj top))))))) )))
	     (content (promise-box result)))
	(let ((key (car content)))
	  (if (eq? key 'eager)
	      (%apply-to-intercepted success (cdr content))
	      (if (eq? key 'failed)
		  (let ((ex (cadr content)))
		    (if (procedure? fh) (fh ex) (raise ex)))
		  #;(apply force result fail)
		  (force result fh success)))))
      obj))

)
