import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";
import { supportedAgents } from "@/lib/site";

// Plain strings (not JSX) so the same copy feeds both the rendered accordion
// and the FAQPage structured data below.
const faqs: { question: string; answer: string }[] = [
  {
    question: "Is Termio free?",
    answer:
      "Yes. Termio is free to use — every feature, no trial clock, no license key, no card. Just download it and go.",
  },
  {
    question: "How do I get updates?",
    answer:
      "Automatically. Termio ships with built-in auto-updates, so once you download it the app keeps itself current — no reinstalling, no checking a website.",
  },
  {
    question: "Do I need an account?",
    answer:
      "No. Download Termio and use every feature — the app runs entirely on your Mac, with no sign-in and no card.",
  },
  {
    question: "Which agents are supported?",
    answer: `Termio gives a first-class native terminal to ${supportedAgents.join(", ")}. Because each session is just a real PTY, any CLI-based agent works — and we add more as the ecosystem grows.`,
  },
  {
    question: "Is there an iPhone app?",
    answer:
      "Yes. The free iPhone companion mirrors your Mac sessions live — the full terminal, with a key bar for esc, tab and ctrl, plus hold-to-speak voice input. It's in public beta on TestFlight; pair it by scanning the QR code in Settings → Mobile.",
  },
  {
    question: "Is my code private?",
    answer:
      "Yes. Termio is local-only: no telemetry, no cloud sync, and no account is needed to start. Your repositories, agent output and sessions never leave your machine.",
  },
  {
    question: "Is Termio available in my language?",
    answer:
      "Termio and the iPhone companion ship in English and Simplified Chinese. The app follows your macOS language; Settings → General pins one if you'd rather choose.",
  },
  {
    question: "What are the requirements?",
    answer:
      "macOS 14 or later, on Apple silicon or Intel — Termio ships as a universal binary, so the same download runs natively on both. You bring your own agent CLIs and their API keys.",
  },
];

// FAQPage structured data so the questions are eligible for rich results.
const faqJsonLd = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: faqs.map((faq) => ({
    "@type": "Question",
    name: faq.question,
    acceptedAnswer: { "@type": "Answer", text: faq.answer },
  })),
};

export function Faq() {
  return (
    <section id="faq" className="scroll-mt-24">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faqJsonLd) }}
      />
      {/* Light top padding — the section above already ends with pb-32/40, so a
          full py-32 here would double the gap. */}
      <div className="mx-auto w-full max-w-2xl px-5 pb-32 pt-8 sm:pb-40 sm:pt-10 sm:px-8">
        <Reveal className="flex flex-col items-center text-center">
          <SectionLabel accent="muted">Support</SectionLabel>
          <h2 className="mt-4 text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
            Frequently asked questions
          </h2>
          <p className="mt-5 max-w-md text-balance text-base leading-relaxed text-muted-foreground">
            Can&apos;t find the answer you&apos;re looking for? The docs go deeper,
            or reach out and a human will help.
          </p>
        </Reveal>

        <Reveal delayMs={80} className="mt-10">
          <Accordion className="border-t border-border">
            {faqs.map((faq) => (
              <AccordionItem key={faq.question} value={faq.question}>
                <AccordionTrigger className="items-center py-5 text-base font-medium">
                  {faq.question}
                </AccordionTrigger>
                <AccordionContent className="pr-8 text-muted-foreground">
                  <p>{faq.answer}</p>
                </AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </Reveal>
      </div>
    </section>
  );
}
