/* ============================================================
   Bonk — Main interactions
   导航 / 移动端菜单 / 滚动入场 / 平滑滚动
   ============================================================ */

(() => {
  /* ---------- 1. 导航滚动毛玻璃 ---------- */
  const nav = document.getElementById("nav");
  let ticking = false;

  function onScroll() {
    if (!ticking) {
      window.requestAnimationFrame(() => {
        if (nav) nav.classList.toggle("scrolled", window.scrollY > 16);
        ticking = false;
      });
      ticking = true;
    }
  }
  window.addEventListener("scroll", onScroll, { passive: true });

  /* ---------- 2. 移动端菜单 ---------- */
  const navToggle = document.getElementById("nav-toggle");
  function closeMenu() {
    if (nav) nav.classList.remove("is-open");
    if (navToggle) navToggle.setAttribute("aria-expanded", "false");
  }
  if (navToggle && nav) {
    navToggle.addEventListener("click", () => {
      const open = nav.classList.toggle("is-open");
      navToggle.setAttribute("aria-expanded", String(open));
    });
    nav
      .querySelectorAll(".nav__link")
      .forEach((link) => link.addEventListener("click", closeMenu));
  }

  /* ---------- 3. 滚动入场动画 ---------- */
  const revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && revealEls.length) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.1, rootMargin: "0px 0px -60px 0px" },
    );
    revealEls.forEach((el) => io.observe(el));
  } else {
    revealEls.forEach((el) => el.classList.add("is-visible"));
  }

  /* ---------- 4. 平滑滚动 ---------- */
  document.querySelectorAll('a[href^="#"]').forEach((anchor) => {
    anchor.addEventListener("click", (e) => {
      const href = anchor.getAttribute("href");
      if (href === "#" || href.length < 2) return;
      const target = document.querySelector(href);
      if (target) {
        e.preventDefault();
        const navHeight = nav ? nav.offsetHeight : 0;
        const top =
          target.getBoundingClientRect().top + window.scrollY - navHeight - 8;
        window.scrollTo({ top, behavior: "smooth" });
      }
    });
  });
})();
