<script lang="ts">
  import "./styles.css";

  const title: string = 42;
  const unused = true;
  let count = $state(0);
</script>

<main class="p-4 text-sm">
  {title}
  <button onclick={() => count++}>{count}</button>
  <output>{count.toFixed(0)}</output>
</main>
