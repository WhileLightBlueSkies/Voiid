// Slug -> rules module. Adding a game is one import and one array entry here; nothing in
// index.ts changes. The slug must match the `games.slug` column seeded in the migration —
// that string is the single join between the catalog row, the folder, and the renderer.
import type { GameFactory } from './GameEngine';
import { tictactoe } from './tictactoe';
import { rps } from './rps';
import { cricket } from './cricket';
import { snake } from './snake';
import { seabattle } from './seabattle';

const FACTORIES: GameFactory[] = [tictactoe, rps, cricket, snake, seabattle];

const bySlug = new Map<string, GameFactory>(FACTORIES.map((f) => [f.slug, f]));

export function factoryFor(slug: string): GameFactory | undefined {
  return bySlug.get(slug);
}
