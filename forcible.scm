(use srfi-18)
(require-library pigeon-hole llrb-tree)

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
 (import (except chicken make-promise promise?))
 (import srfi-18)
 (import (prefix pigeonry threadpool-))
 (import llrb-tree)

(define-record forcible-timeout)

(define %forcible-timeout (make-forcible-timeout))

(define (timeout-condition? x) (eq? x %forcible-timeout))

(include "timeout.scm")

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

#;(define (make-delayed-promise thunk)
  (lazy (call-with-values thunk eager)))

;; Manually inlined for speed.
(define (make-delayed-promise thunk)
  (make-promise (cons (make-mutex 'delayed) (lambda () (call-with-values thunk eager)))))

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
		       (receive
			results (thunk)
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

(define-inline (unlock-promise-mutex! key)
  #;(cancel-promise-timeout! key)
  #;(assert (eq? (mutex-state (dbg (current-thread) key)) (current-thread)))
  (mutex-unlock! key))

(define-inline (unlock-other-promise-mutex! key)
  #;(cancel-promise-timeout! key)
  (mutex-unlock! key))

(: fulfil!* (:promise: boolean list -> boolean))
(define (fulfil!* promise type args)
  (let* ((content (promise-box promise))
	 (key (car content)))
    (if (symbol? key) #f
	(begin
	  (set-cdr! content args)
	  (set-car! content (if type 'eager 'failed))
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
	 (promise (if thunk
		      (make-delayed-promise thunk)
		      (make-promise (list mux)))))
    (if (not thunk)
	(mutex-lock! mux #f #f))
    (values
     (lambda (kind . args) (fulfil!* promise kind args))
     promise)))

(define make-order-promise
  (begin
    (define poo-type
      (threadpool-make-type
       (lambda (promise ex) (fulfil! promise #f ex))
       #f #;(lambda (root) #f)))
    ;;(define (pileup promise thunk) (receive args (thunk) (fulfil!* promise #t args)))
    (define (pileup promise) (receive args ((cadr (promise-box promise))) (fulfil!* promise #t args)))
    (define (pileup/timeout promise timeout)
      (let ((to (register-timeout-message! timeout ##sys#current-thread)))
	(receive
	 args ((cadr (promise-box promise)))
	 (cancel-timeout-message! to)
	 (fulfil!* promise #t args))))
    ;; Pool is currently NOT REALLY limited.
    (define pile (threadpool-make 'pile #t poo-type))
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

(define (make-delayed-promise/timeout-ex thunk timeout)
  (make-promise
   (cons
    (make-mutex 'delayed/timeout)
    (lambda ()
      (let* ((to (register-timeout-message! timeout ##sys#current-thread))
	     (result (call-with-values thunk eager)))
	(cancel-timeout-message! to)
	result)))))

(define-syntax delay/timeout
  (syntax-rules ()
    ((_ exp) (make-delayed-promise (lambda () exp)))
    ((_ to exp) (make-delayed-promise/timeout-ex (lambda () exp) to))))

(: force1! (:promise: (or false (procedure (*) undefined)) -> :promise:))
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
		  (top (promise-box promise)))
	      (loop promise))))
       ((thread? key)
	(if (eq? (thread-state key) 'created) (thread-start! key))
	(receive
	 vals (thread-join! key)
	 (let ((content (promise-box promise)))
	   (if (not (symbol? (car content)))
	       (begin
		 (set-car! content 'eager)
		 (set-cdr! content vals))))
	 (loop promise)))
       (else (error "forcible: unknown promise kind" key))))))

(: force (* &optional (or (procedure (*) . *) false) -> . *))
(define (force obj . fail)
  (if (promise? obj)
      (let* ((fh (and (pair? fail) (car fail)))
	     (key (car (promise-box obj)))
	     (result
	      (cond
	       ;; Result already available.
	       ((symbol? key) obj)
	       ;; As CHICKEN makes it hard to not catch exceptions in
	       ;; threads we don't to so anymore.  Hence no exceptions here:
	       ((thread? key) (force1! obj #f))
	       ;; Backward compatible case does not cache exceptions.
	       ((and (pair? fail) (not fh))
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
			  (let ((last (promise-box obj)))
			    (handle-exceptions
			     ex
			     (let ((result (list 'failed ex)))
			       (promise-box-set! obj result)
			       (if (not (eq? last (promise-box obj)))
				   (let ((lastkey (car last)))
				     (when
				      (not (eq? lastkey key))
				      (set-cdr! last result)
				      (set-car! last 'failed)
				      (mutex-unlock! lastkey))))
			       (unlock-promise-mutex! key)
			       obj)
			     (force1! obj (lambda (b) (set! last b)))))))) )))
	     (content (promise-box result)))
	(if (eq? (car content) 'eager)
	    (apply values (cdr content))
	    (let ((ex (cadr content)))
	      (if (procedure? fh) (fh ex) (raise ex)))))
      obj))

)
