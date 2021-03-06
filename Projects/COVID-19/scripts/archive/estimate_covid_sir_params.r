library(tidyverse)
library(R0)
library(scales)
library(incidence)
library(EpiDynamics)
library(spatstat)

param_dat = expand.grid(
  initial_r0 = seq(2, 3, by = 0.25),
  incubation_period = seq(4, 7, by = 0.5),
  distancing_effect = seq(0.4, 0.7, by = 0.05),
  prop_susceptible = seq(0.3, 0.7, by = 0.1),
  initial_shutdown = c('2020-03-07') %>% as.Date(),
  missing_death_rate = seq(0.30, 0.60, by = 0.05)
)

setwd("~/Public_Policy/Projects/COVID-19")
italy_jh_joined = read_csv('data/jh_joined.csv') %>% filter(country_region == 'Italy') %>% 
  filter(cases > 0) %>%
  mutate(
    time = as.numeric(date_upd - min(date_upd)),
    new_deaths = c(deaths[1], diff(deaths, 1)),
    days_since_first_death = as.numeric(date_upd - min(date_upd[deaths > 0])),
    weeks_since_first_death = days_since_first_death %/% 7
  )


italy_jh_joined_weekly_deaths = group_by(italy_jh_joined, weeks_since_first_death) %>%
  summarize(
    obs = n(),
    total_deaths = sum(new_deaths)
  ) %>%
  mutate(
    projected = total_deaths / (obs/7)
  )

run_sir_sim = function(the_row, return_data = F){
  
  # the_row = param_dat[it,]
  # the_row = these_params
  # 
  # the_row = tibble(
  #   initial_r0 = 2.25,
  #   incubation_period = 5, 
  #   distancing_effect = 0.6, 
  #   prop_susceptible = 0.3, 
  #   missing_death_rate = 0.4,
  #   initial_shutdown = as.Date('2020-03-07')
  # )
  initial_r0 = the_row$initial_r0
  
  distancing_effect = the_row$distancing_effect
  distancing_r0 = initial_r0 * (1- distancing_effect)
  
  incubation_period = the_row$incubation_period
  gamma = 1/incubation_period
  
  initial_beta = initial_r0 / incubation_period
  secondary_beta = distancing_r0 / incubation_period
  
  italy_pop = 60.36e6
  italy_susceptible = italy_pop * the_row$prop_susceptible
  
  missing_death_rate = the_row$missing_death_rate 
  
  ##### pull in data ####
  
  
  initial_shutdown = the_row$initial_shutdown
  first_cases = min(italy_jh_joined$date_upd)
  initial_r0_period = as.numeric(initial_shutdown - first_cases) - 1
  
  secondary_period = as.numeric(max(italy_jh_joined$date_upd) - initial_shutdown)
  total_time = initial_r0_period + secondary_period - 1 + 60
  time_since_initial_case = as.numeric(max(italy_jh_joined$date_upd) - min(italy_jh_joined$date_upd))
  
  # covid
  initial_parameters <- c(beta = initial_beta, gamma = gamma)
  initials <- c(S = 1 - 1e-06, I = 1e-06, R = 1 - (1 - 1e-06 - 1e-06))
  
  initial_covid_sir <- SIR(pars = initial_parameters, init = initials, time = 0:initial_r0_period)
  
  secondary_parameters <- c(beta = secondary_beta, gamma = gamma)
  secondary_initials <- c(S = tail(initial_covid_sir$results$S, 1), I = tail(initial_covid_sir$results$I, 1), 
                          R = tail(initial_covid_sir$results$R, 1))
  
  distancing_covid_sir = SIR(pars = secondary_parameters, init = secondary_initials, time = (initial_r0_period+1):total_time)
  
  # combine sirs
  

  est_deaths = function(par, missing_death_rate, return_dat = F) {
    
    death_rate = par[1]
    
    combined_sirs = 
      tibble(
        time = initial_covid_sir$time,
        S = initial_covid_sir$results$S,
        I = initial_covid_sir$results$I,
        R = initial_covid_sir$results$R,
        model = 'initial'
      ) %>%
      bind_rows(
        tibble(
          time = distancing_covid_sir$time - 1,
          S = distancing_covid_sir$results$S,
          I = distancing_covid_sir$results$I,
          R = distancing_covid_sir$results$R,
          model = 'secondary'
        ) %>%
          filter(time != min(time))
      ) %>%
      mutate(
        new_cases = round(lag(S * italy_susceptible, 1) - S*italy_susceptible),
        deaths = rbinom(length(S), new_cases, prob = death_rate),
        death_timing = rweibull(length(S), 3, 10),
        death_date =  round(time + death_timing),
        days_since_first_death = death_date - min(death_date[deaths > 0], na.rm = T),
        death_week = days_since_first_death %/% 7
      )
    
    # # [1] 3.005484 7.201339
    # the_weibull = rweibull(1000, the_solution$par[1], the_solution$par[2])
    # # 
    
    sir_weekly_deaths = group_by(combined_sirs, death_week) %>%
      summarize(
        sir_total_deaths = sum(deaths, na.rm = T)
      ) 
    
    weekly_comparison = inner_join(italy_jh_joined_weekly_deaths, sir_weekly_deaths, 
                                   by = c('weeks_since_first_death' = 'death_week')) %>%
      mutate(
        italy_true_death_estimate = projected / (1-missing_death_rate),
        diff_sir_total_deaths_true = sir_total_deaths - italy_true_death_estimate,
        squared_diff_sir_total_deaths_true = diff_sir_total_deaths_true^2
      )
    
    
    # use projected here
    italy_reported_deaths_to_date = sum(weekly_comparison$projected)
    italy_true_death_estimate = italy_reported_deaths_to_date / (1-missing_death_rate)
    sir_deaths_to_date = sum(weekly_comparison$sir_total_deaths)
    difference_sir_true_est = sum(weekly_comparison$squared_diff_sir_total_deaths_true)
    
    if (return_dat) {
      return(combined_sirs)
    } else {
      return(difference_sir_true_est)  
    }
  }
  
  the_solution = optim(par = 0.01, fn = est_deaths, method = 'Brent', lower = 0.001, upper = 0.05, missing_death_rate = missing_death_rate)
  
  # > the_solution$par
  # [1] 0.003152483
  
  sir_dat = est_deaths(the_solution$par, return_dat = T, missing_death_rate = missing_death_rate) 
  head(sir_dat)
  
  sir_weekly_deaths = group_by(sir_dat, death_week) %>%
    summarize(
      sir_total_deaths = sum(deaths, na.rm = T)
    ) 
  
  weekly_comparison = inner_join(italy_jh_joined_weekly_deaths, sir_weekly_deaths, by = c('weeks_since_first_death' = 'death_week')) %>%
    mutate(
      italy_true_death_estimate = projected / (1-missing_death_rate),
    )
  
  return_dat = tibble(
    weekly_correlation = cor(weekly_comparison$projected, weekly_comparison$sir_total_deaths),
    solution_diff = the_solution$value^(1/2),
    solved_ifr = the_solution$par,
    sir_total_deaths = sum(sir_weekly_deaths$sir_total_deaths),
    sir_total_observed_deaths = sum(sir_weekly_deaths$sir_total_deaths) * (1-missing_death_rate),
    sir_observed_to_date = sum(weekly_comparison$sir_total_deaths) * (1-missing_death_rate),
    actual_to_date = sum(weekly_comparison$total_deaths),
    projected_to_date = sum(weekly_comparison$projected),
    actual_projected_not_missing = sum(weekly_comparison$projected) / (1-missing_death_rate)
  )
  
  if (return_data) {
    return(
      list(
        weekly_comparison = weekly_comparison,
        sir_dat = sir_dat,
        return_dat = return_dat,
        sir_weekly_deaths = sir_weekly_deaths
      )
    )
  } else {
    return(return_dat)  
  }
}

all_italy_runs = map(1:nrow(param_dat), function(it){
  print(it/nrow(param_dat))
  
  run_sir_sim(param_dat[it,])
}) %>% 
  bind_rows() 

param_dat$it = 1:nrow(param_dat)

all_italy_runs_with_params = inner_join(all_italy_runs %>% mutate(it = 1:nrow(all_italy_runs)), param_dat) %>%
  arrange(solution_diff, -weekly_correlation) %>%
  mutate(
    weekly_correlation = ifelse(weekly_correlation < 0, 0, weekly_correlation)
  )

write.csv(all_italy_runs_with_params, 
          'data/all_italy_runs_with_params.csv', row.names = F)

# limit to the most plausible solutions

all_italy_runs_with_params$weekly_correlation %>% hist()
weighted.mean(all_italy_runs_with_params$solved_ifr, all_italy_runs_with_params$weekly_correlation^2)
weighted.quantile(all_italy_runs_with_params$solved_ifr, all_italy_runs_with_params$weekly_correlation^(2), probs=seq(0,1,0.25), na.rm = TRUE)

ggplot(all_italy_runs_with_params, aes(distancing_effect, initial_r0 )) +
  geom_point() +
  # geom_tile(aes(fill = solution_diff, alpha = weekly_correlation^2)) +
  scale_fill_viridis_d(direction = -1)

# get top ten percent as solution set
mean(top_10$solved_ifr)
ggplot(top_10, aes(weekly_correlation, solved_ifr, colour = initial_r0)) +
  geom_point()

weighted.mean(top_10$solved_ifr, top_10$weekly_correlation^2)
weighted.quantile(top_10$solved_ifr, top_10$weekly_correlation^(2), probs=seq(0,1,0.25), na.rm = TRUE)

all_italy_runs_with_params$solution_diff %>% summary()

solution_set = filter(all_italy_runs_with_params, solution_diff <= 1000) %>%
  arrange(-weekly_correlation)
solution_set$solution_diff %>%  hist()

ggplot(solution_set, aes(weekly_correlation^2, solved_ifr)) +
  geom_point(aes(colour = initial_r0))  +
  scale_colour_viridis_c(option = 'C') +
  theme_dark() +
  stat_smooth()
  

these_params = filter(param_dat, it %in% head(solution_set, 1)$it)
the_dat = run_sir_sim(these_params, T)
names(the_dat)
the_dat$sir_dat
ggplot(the_dat$sir_dat, aes(time, new_cases)) +
  geom_bar(stat = 'identity')
ggplot(the_dat$sir_dat, aes(time, I)) +
  geom_line()


sum(the_dat$sir_dat$new_cases, na.rm = T)
the_dat$sir_weekly_deaths

ggplot(the_dat$sir_weekly_deaths, aes(death_week , sir_total_deaths*(1-these_params$missing_death_rate))) +
  geom_bar(stat = 'identity')

ggplot(the_dat$weekly_comparison, aes(weeks_since_first_death)) +
  geom_area(aes(y = projected), alpha = 0.5) +
  geom_area(aes(y = sir_total_deaths), alpha = 0.5, fill = 'red')

the_dat$sir_weekly_deaths
sum(the_dat$sir_weekly_deaths*(1-these_params$missing_death_rate))

the_dat$weekly_comparison
ggplot(the_dat$sir_dat, aes(death_date, deaths)) +
  geom_bar(stat = 'identity')


weighted.mean(solution_set$solved_ifr, solution_set$weekly_correlation^2)
weighted.quantile(solution_set$solved_ifr, solution_set$weekly_correlation^(2), probs=seq(0,1,0.25), na.rm = TRUE)
head(solution_set, 5) %>% View()

ggplot(solution_set, aes(weekly_correlation, initial_r0, colour = solved_ifr)) +
  geom_point() +
  scale_colour_viridis_c()

head(all_italy_runs_with_params)
names(all_italy_runs_with_params)
avg_by_param

ggplot(all_italy_runs_with_params, aes(initial_r0, solved_ifr, fill = weekly_correlation, alpha = weekly_correlation)) +
  geom_point()
all_italy_runs_with_params$solved_ifr

ggplot(solution_set, aes(initial_r0, distancing_effect, fill = weekly_correlation)) +
  scale_fill_viridis_c() +
  geom_tile() +
  scale_x_continuous(breaks = seq(2, 3, by = 0.25))

filter(solution_set, distancing_effect == 0.6, initial_r0 == 2.25) %>% arrange(-weekly_correlation) 
solution_set$initial_r0
