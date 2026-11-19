"use client";

import { useEffect, useRef, useState } from "react";

// A feature loop that a reader can stop. It plays only while on screen, and not
// at all when the system asks for reduced motion: then the poster stands in and
// the button offers to play it once asked.
export function FeatureVideo({ name, label }: { name: string; label: string }) {
  const ref = useRef<HTMLVideoElement>(null);
  const [playing, setPlaying] = useState(false);
  const [wanted, setWanted] = useState(true);

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    // The system setting can change while the page is open; follow it.
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const onMotion = () => setWanted(!motion.matches);
    onMotion();
    motion.addEventListener("change", onMotion);
    // The button shows what the element is doing, not what was asked of it: a
    // play() that fails, or a source that cannot load, ends on Play.
    const sync = () => setPlaying(!video.paused && !video.error);
    const events = ["play", "playing", "pause", "error", "emptied"] as const;
    events.forEach((name) => video.addEventListener(name, sync));
    return () => {
      motion.removeEventListener("change", onMotion);
      events.forEach((name) => video.removeEventListener(name, sync));
    };
  }, []);

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting && wanted) {
        video.play().catch((error) => {
          console.warn("Feature video did not start", error);
          setPlaying(!video.paused && !video.error);
        });
      } else {
        video.pause();
      }
    });
    observer.observe(video);
    return () => observer.disconnect();
  }, [wanted]);

  return (
    <>
      <video
        ref={ref}
        src={`/videos/${name}.mp4`}
        poster={`/videos/${name}-poster.jpg`}
        muted
        loop
        playsInline
        preload="metadata"
        aria-label={label}
        className="absolute inset-0 size-full object-cover"
      />
      <button
        type="button"
        onClick={() => {
          const video = ref.current;
          if (!video) return;
          setWanted(!playing);
          if (playing) {
            video.pause();
          } else {
            video.play().catch((error) => {
              console.warn("Feature video did not start", error);
              setPlaying(!video.paused && !video.error);
            });
          }
        }}
        aria-label={playing ? "Pause video" : "Play video"}
        className="absolute bottom-3 right-3 inline-flex size-8 items-center justify-center rounded-full bg-black/40 text-white/80 backdrop-blur-md transition-colors hover:bg-black/60 hover:text-white"
      >
        <svg
          viewBox="0 0 16 16"
          width="12"
          height="12"
          aria-hidden="true"
          fill="currentColor"
        >
          {playing ? (
            <path d="M4 3h3v10H4zM9 3h3v10H9z" />
          ) : (
            <path d="M5 3l8 5-8 5z" />
          )}
        </svg>
      </button>
    </>
  );
}
