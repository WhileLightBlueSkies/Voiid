// The one place a failed request becomes a response (P03).
//
// ── WHAT THIS REPLACES ───────────────────────────────────────────────────────────
//
// A middleware that decided the status by running a regex over the error MESSAGE:
//
//     const status = err?.type === 'entity.parse.failed' || /base64|invalid input/i.test(...)
//       ? 400 : 500;
//
// Two failures came out of that. A body-too-large error arrives from body-parser carrying its
// own `status: 413`, and was answered 500 — telling a client to retry something that will
// never succeed. And any internal failure whose text happened to contain "invalid input" was
// reported to the caller as their mistake: Postgres says exactly that for a bad uuid cast,
// which is our bug, not theirs.
//
// The rule now is: an error that KNOWS its status is believed, and everything else is a 500.
// Nothing is inferred from prose.
import { randomUUID } from 'crypto';
import type { Express, NextFunction, Request, Response } from 'express';

/** Errors we raise deliberately, with a status and a stable machine-readable code. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}

/**
 * What body-parser reports, mapped to what the caller should be told.
 *
 * These come from the parser rather than from us, so they are matched on `type` — a stable
 * identifier body-parser sets — never on the message.
 */
const PARSER_CODES: Record<string, { status: number; code: string }> = {
  'entity.parse.failed': { status: 400, code: 'invalid_json' },
  'entity.too.large': { status: 413, code: 'payload_too_large' },
  'request.aborted': { status: 400, code: 'request_aborted' },
  'request.size.invalid': { status: 400, code: 'invalid_content_length' },
  'parameters.too.many': { status: 413, code: 'too_many_parameters' },
  'encoding.unsupported': { status: 415, code: 'unsupported_encoding' },
  'charset.unsupported': { status: 415, code: 'unsupported_charset' },
};

interface Classified {
  status: number;
  code: string;
}

/** Pure, so the mapping can be tested without a socket. */
export function classifyError(err: any): Classified {
  if (err instanceof HttpError) return { status: err.status, code: err.code };

  const byType = typeof err?.type === 'string' ? PARSER_CODES[err.type] : undefined;
  if (byType) return byType;

  // Anything else that carries an explicit status is believed — routes and middleware set
  // `status`/`statusCode` when they mean it. A 5xx there is still a 5xx.
  const declared = Number(err?.status ?? err?.statusCode);
  if (Number.isInteger(declared) && declared >= 400 && declared <= 599) {
    return { status: declared, code: typeof err?.code === 'string' ? err.code : declared >= 500 ? 'internal_error' : 'bad_request' };
  }

  // No opinion expressed. It is ours.
  return { status: 500, code: 'internal_error' };
}

/**
 * Install the global handler.
 *
 * Also stamps a request id, because "internal error" with nothing to search by is not an
 * answer anybody can act on — the caller quotes the id and it is in the log line.
 */
export function installErrorHandler(app: Express): void {
  app.use((err: any, req: Request, res: Response, _next: NextFunction) => {
    const { status, code } = classifyError(err);
    const requestId = (req as any).id ?? randomUUID();

    if (status >= 500) {
      // The message is logged and never returned: this is where SQL text, connection strings
      // and provider detail would otherwise reach the caller.
      // The route PATTERN (`/clips/:id`), not the concrete path: which endpoint failed is
      // what makes the line actionable, and a pattern carries no ids or tokens.
      const route = `${req.method} ${req.baseUrl ?? ''}${req.route?.path ?? '(unmatched)'}`;
      console.error(`[voiid:api] ${requestId} ${route} unhandled error:`, err?.message ?? err);
    }

    // A handler that already began a response cannot be given another one. Ending the
    // response is still better than leaving the socket open.
    if (res.headersSent) return res.end();

    res.setHeader('x-request-id', requestId);
    res.status(status).json({
      error: status >= 500 ? 'internal error' : 'bad request',
      code,
      request_id: requestId,
    });
  });
}
