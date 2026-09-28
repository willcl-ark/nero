function jumpToRalph() {
  if (window.location.hash !== '#author-ralph') return;

  const author = document.querySelector('.comment-header a.author[href="/ralph"]');
  const comment = author?.closest('[id^="issuecomment-"]');
  comment?.scrollIntoView({block: 'center'});
}

window.addEventListener('load', jumpToRalph);
window.addEventListener('hashchange', jumpToRalph);
