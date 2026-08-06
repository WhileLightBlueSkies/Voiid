import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { CTA } from '../../components/CTA';
import { PhoneMockup, PhoneAppBar } from '../../components/PhoneMockup';

export const metadata: Metadata = {
  title: 'Games',
  description:
    'Four games you can play with a friend from inside the chat. The server referees ' +
    'the match, so game moves are not end-to-end encrypted.',
};

/*
 * CLAIMS CHECKED (README rule 2):
 *   - EXACTLY FOUR games are seeded: tictactoe + rps (024_games.sql), cricket
 *     (025_games_hand_cricket.sql), snake (026_games_snake.sql). Do not add a fifth
 *     here before it is seeded there.
 *   - Game state is server-refereed and therefore NOT E2EE — 024_games.sql header.
 *   - The invite itself is an ordinary encrypted message; only the match state is public.
 *   - Invites require a reachable opponent (games.ts reachableOpponents).
 */
export default function GamesPage() {
  return (
    <>
      <Hero
        hue="games"
        eyebrow="Games"
        title={<>Play a friend without leaving the conversation.</>}
        lede={
          <>
            Four games, played inside the chat you were already having. The invite arrives as
            an ordinary encrypted message; the match itself is refereed by our server, which
            means the moves are not private — and that is worth being clear about.
          </>
        }
        badges={<E2EEBadge state="refereed" detail="Moves, scores and results" />}
        aside={
          <PhoneMockup hue="games" tilt="left" label="A game invite in chat" decorative>
            <PhoneAppBar title="Priyanshu" subtitle="Hand Cricket" />
          </PhoneMockup>
        }
      />

      <Section hue="games" eyebrow="The catalogue" title="Four games, properly finished">
        <Grid>
          <FeatureCard title="Tic Tac Toe" glyph="games" hue="games">
            The one everybody already knows the rules to. Best of nothing, settled in a minute.
          </FeatureCard>
          <FeatureCard title="Rock Paper Scissors" glyph="games" hue="games">
            Simultaneous moves, which is exactly the case a referee is needed for — neither
            phone can be trusted to reveal second.
          </FeatureCard>
          <FeatureCard title="Hand Cricket" glyph="games" hue="games">
            The playground classic. Bat, bowl, and lose your wicket to a matching number.
          </FeatureCard>
          <FeatureCard title="Snake" glyph="games" hue="games">
            Arcade Snake, refereed frame by frame so a modified client cannot simply declare
            itself the winner.
          </FeatureCard>
        </Grid>
      </Section>

      <Section
        hue="games"
        tone="raised"
        eyebrow="Why the server sees this"
        title="A referee has to see the game"
        width="narrow"
      >
        <p>
          Two phones cannot agree on who won without either trusting each other or trusting
          something in the middle. Trusting each other means the first modified client wins
          every match. So our server holds the rules and validates every move — which requires
          it to read them.
        </p>
        <Callout tone="honest" title="What is public here">
          Moves, scores and results. The <em>invitation</em> is an ordinary end-to-end
          encrypted message like any other; only the match state is server-readable. Nothing
          about a game reaches anyone outside it.
        </Callout>
        <p>
          Invites follow the same reachability rules as messages: you can only invite someone
          you could already message. A game invite is not a way around the PIN.
        </p>
      </Section>

      <CTA
        hue="games"
        title="Encrypted, and not"
        lede="Every surface in one place, with no hedging."
        actions={<></>}
        note={<>See the <a href="/privacy">privacy page</a>.</>}
      />
    </>
  );
}
