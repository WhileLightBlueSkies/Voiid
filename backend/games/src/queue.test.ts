// Per-match queue test. Run: npx tsx src/queue.test.ts
//
// The queue is what makes §7.3's atomicity real in-process: two frames for one match must
// never interleave. These checks pin the ordering guarantee without needing Redis.
import { enqueue, drainQueue, clearQueues } from './queue';

let failures = 0;
let passes = 0;

function check(name: string, cond: boolean, detail = ''): void {
    if (cond) {
        passes++;
        console.log(`  PASS  ${name}`);
    } else {
        failures++;
        console.error(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
    }
}

async function main(): Promise<void> {
    console.log('\nper-match command queue');

    {
        clearQueues();
        const order: number[] = [];
        // All three jobs are dispatched before any of them runs.
        await Promise.all([
            enqueue('m', async () => { order.push(1); }),
            enqueue('m', async () => { order.push(2); }),
            enqueue('m', async () => { order.push(3); }),
        ]);
        check('same-key jobs run strictly in arrival order', JSON.stringify(order) === '[1,2,3]', JSON.stringify(order));
    }

    {
        clearQueues();
        // Interleaving simulation: job A awaits an I/O tick mid-flight; job B must wait for
        // A to FULLY finish (load → apply → save) before it starts.
        const log: string[] = [];
        const a = enqueue('k', async () => {
            log.push('a:load');
            await new Promise((r) => setTimeout(r, 20));
            log.push('a:apply');
            await new Promise((r) => setTimeout(r, 5));
            log.push('a:save');
        });
        const b = enqueue('k', async () => { log.push('b:ran'); });
        await Promise.all([a, b]);
        check('a later frame cannot interleave between load/apply/save of an earlier one',
            log.join('|') === 'a:load|a:apply|a:save|b:ran', log.join('|'));
    }

    {
        clearQueues();
        // Different keys are independent — one slow match never blocks another.
        let slowDone = false;
        const slow = enqueue('slow', async () => {
            await new Promise((r) => setTimeout(r, 30));
            slowDone = true;
        });
        const fast = await enqueue('fast', async () => 'fast-ok');
        check('independent keys do not serialize against each other',
            fast === 'fast-ok' && !slowDone);
        await slow;
    }

    {
        clearQueues();
        // A throwing job neither poisons the queue nor loses later jobs.
        const results = await Promise.allSettled([
            enqueue('e', async () => { throw new Error('boom'); }),
            enqueue('e', async () => 'after-boom'),
        ]);
        check('a throwing job does not poison subsequent ones',
            results[0].status === 'rejected' &&
            results[1].status === 'fulfilled' &&
            (results[1] as PromiseFulfilledResult<string>).value === 'after-boom');
        await drainQueue('e');
    }
}

void main()
    .then(() => {
        console.log(`\n${passes} passed, ${failures} failed`);
        if (failures > 0) process.exit(1);
    })
    .catch((err) => {
        console.error(err);
        process.exit(1);
    });
